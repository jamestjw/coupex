use rand::rngs::StdRng;
use rand::SeedableRng;
use rusty_duke::engine::{
    Bot, HeuristicBot, HeuristicProfile, IsmctsBot, RolloutPolicyKind, SearchConfig,
};
use rusty_duke::{
    ActionKind, Card, DeclaredAction, Move, Observation, ObservedPlayer, Phase, PlayerId,
};
use serde_json::{json, Value};

#[rustler::nif]
fn choose_move(payload: String) -> Result<String, String> {
    let payload: Value = serde_json::from_str(&payload).map_err(|error| error.to_string())?;
    let seed = payload.get("seed").and_then(Value::as_u64).unwrap_or(1);
    let profile = parse_profile(
        payload
            .get("profile")
            .and_then(Value::as_str)
            .unwrap_or("balanced"),
    );
    let observation = parse_observation(&payload)?;
    let mut rng = StdRng::seed_from_u64(seed);

    let chosen = match payload
        .get("strategy")
        .and_then(Value::as_str)
        .unwrap_or("heuristic")
    {
        "ismcts" => {
            let iterations = payload
                .get("iterations")
                .and_then(Value::as_u64)
                .unwrap_or(250) as usize;

            let mut bot = IsmctsBot::new(SearchConfig {
                iterations,
                max_depth: 80,
                exploration: 1.4,
                rollout_policy: RolloutPolicyKind::Heuristic(profile),
            });

            bot.choose_move(&observation, &mut rng)
        }
        _ => {
            let mut bot = HeuristicBot::new(profile);
            bot.choose_move(&observation, &mut rng)
        }
    };

    chosen
        .map(move_to_json)
        .map(|value| value.to_string())
        .ok_or_else(|| "rusty-duke returned no legal move".to_string())
}

fn parse_observation(payload: &Value) -> Result<Observation, String> {
    let viewer = parse_usize(payload, "viewer")?;
    let players = payload
        .get("players")
        .and_then(Value::as_array)
        .ok_or_else(|| "missing players".to_string())?;

    let observed_players = players
        .iter()
        .map(parse_player)
        .collect::<Result<Vec<_>, _>>()?;

    let own_hidden_cards = payload
        .get("own_hidden_cards")
        .and_then(Value::as_array)
        .ok_or_else(|| "missing own_hidden_cards".to_string())?
        .iter()
        .map(parse_card_value)
        .collect::<Result<Vec<_>, _>>()?;

    let deck_size = parse_usize(payload, "deck_size")?;
    let phase = parse_phase(payload)?;
    let current_player = active_player(&phase);

    Ok(Observation {
        viewer,
        players: observed_players,
        own_hidden_cards,
        deck_size,
        current_player,
        phase,
    })
}

fn parse_player(value: &Value) -> Result<ObservedPlayer, String> {
    let coins = value
        .get("coins")
        .and_then(Value::as_u64)
        .ok_or_else(|| "missing player coins".to_string())? as u8;

    let hidden_influence = parse_usize(value, "hidden_influence")?;
    let alive = value
        .get("alive")
        .and_then(Value::as_bool)
        .ok_or_else(|| "missing player alive".to_string())?;

    let revealed = value
        .get("revealed")
        .and_then(Value::as_array)
        .ok_or_else(|| "missing player revealed cards".to_string())?
        .iter()
        .map(parse_card_value)
        .collect::<Result<Vec<_>, _>>()?;

    Ok(ObservedPlayer {
        coins,
        hidden_influence,
        revealed,
        alive,
    })
}

fn parse_phase(payload: &Value) -> Result<Phase, String> {
    let phase = payload
        .get("phase")
        .ok_or_else(|| "missing phase".to_string())?;

    match phase.get("kind").and_then(Value::as_str).unwrap_or("") {
        "action" => Ok(Phase::AwaitingAction {
            actor: parse_usize(phase, "actor")?,
        }),
        "challenge" => Ok(Phase::AwaitingChallenge {
            action: parse_action(phase)?,
            responder_index: parse_usize(phase, "responder_index")?,
        }),
        "block" => Ok(Phase::AwaitingBlock {
            action: parse_action(phase)?,
            responder_index: parse_usize(phase, "responder_index")?,
        }),
        "block_challenge" => Ok(Phase::AwaitingBlockChallenge {
            action: parse_action(phase)?,
            blocker: parse_usize(phase, "blocker")?,
            block_card: parse_card_name(required_str(phase, "block_card")?)?,
            responder_index: parse_usize(phase, "responder_index")?,
        }),
        "reveal" => Ok(Phase::AwaitingInfluenceLoss {
            player: parse_usize(phase, "player")?,
            next: Box::new(Phase::AwaitingAction {
                actor: parse_usize(phase, "next_actor")?,
            }),
        }),
        "exchange" => Ok(Phase::AwaitingExchangeReturn {
            player: parse_usize(phase, "player")?,
            drawn: phase
                .get("drawn")
                .and_then(Value::as_array)
                .ok_or_else(|| "missing exchange drawn cards".to_string())?
                .iter()
                .map(parse_card_value)
                .collect::<Result<Vec<_>, _>>()?,
        }),
        other => Err(format!("unsupported phase: {other}")),
    }
}

fn parse_action(value: &Value) -> Result<DeclaredAction, String> {
    let actor = parse_usize(value, "actor")?;
    let target = value
        .get("target")
        .and_then(Value::as_u64)
        .map(|target| target as usize);

    let kind = match required_str(value, "action")? {
        "foreign_aid" => ActionKind::ForeignAid,
        "tax" => ActionKind::Tax,
        "assassinate" => ActionKind::Assassinate {
            target: target.ok_or_else(|| "assassinate missing target".to_string())?,
        },
        "steal" => ActionKind::Steal {
            target: target.ok_or_else(|| "steal missing target".to_string())?,
        },
        "exchange" => ActionKind::Exchange,
        other => return Err(format!("unsupported action: {other}")),
    };

    Ok(DeclaredAction { actor, kind })
}

fn move_to_json(chosen: Move) -> Value {
    match chosen {
        Move::Income => json!({"kind": "take_action", "action": "income"}),
        Move::ForeignAid => json!({"kind": "take_action", "action": "foreign_aid"}),
        Move::Tax => json!({"kind": "take_action", "action": "tax"}),
        Move::Assassinate { target } => {
            json!({"kind": "take_action", "action": "assassinate", "target": target})
        }
        Move::Steal { target } => {
            json!({"kind": "take_action", "action": "steal", "target": target})
        }
        Move::Exchange => json!({"kind": "take_action", "action": "exchange"}),
        Move::Coup { target } => json!({"kind": "take_action", "action": "coup", "target": target}),
        Move::Challenge => json!({"kind": "challenge"}),
        Move::PassChallenge | Move::PassBlock => json!({"kind": "pass"}),
        Move::Block { claim } => json!({"kind": "block", "role": card_to_role(claim)}),
        Move::RevealInfluence { card_index } => json!({"kind": "reveal", "index": card_index}),
        Move::ExchangeReturn { keep } => json!({
            "kind": "exchange",
            "roles": keep.into_iter().map(card_to_role).collect::<Vec<_>>()
        }),
    }
}

fn active_player(phase: &Phase) -> Option<PlayerId> {
    match phase {
        Phase::AwaitingAction { actor } => Some(*actor),
        Phase::AwaitingInfluenceLoss { player, .. } => Some(*player),
        Phase::AwaitingExchangeReturn { player, .. } => Some(*player),
        _ => None,
    }
}

fn parse_usize(value: &Value, key: &str) -> Result<usize, String> {
    value
        .get(key)
        .and_then(Value::as_u64)
        .map(|number| number as usize)
        .ok_or_else(|| format!("missing {key}"))
}

fn required_str<'a>(value: &'a Value, key: &str) -> Result<&'a str, String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("missing {key}"))
}

fn parse_card_value(value: &Value) -> Result<Card, String> {
    parse_card_name(value.as_str().ok_or_else(|| "invalid card".to_string())?)
}

fn parse_card_name(name: &str) -> Result<Card, String> {
    match name {
        "duke" => Ok(Card::Duke),
        "assassin" => Ok(Card::Assassin),
        "captain" => Ok(Card::Captain),
        "ambassador" => Ok(Card::Ambassador),
        "contessa" => Ok(Card::Contessa),
        other => Err(format!("unknown card: {other}")),
    }
}

fn card_to_role(card: Card) -> &'static str {
    match card {
        Card::Duke => "duke",
        Card::Assassin => "assassin",
        Card::Captain => "captain",
        Card::Ambassador => "ambassador",
        Card::Contessa => "contessa",
    }
}

fn parse_profile(profile: &str) -> HeuristicProfile {
    match profile {
        "aggressive" => HeuristicProfile::Aggressive,
        "conservative" => HeuristicProfile::Conservative,
        "economic" => HeuristicProfile::Economic,
        "challenge_heavy" => HeuristicProfile::ChallengeHeavy,
        "block_heavy" => HeuristicProfile::BlockHeavy,
        _ => HeuristicProfile::Balanced,
    }
}

rustler::init!("Elixir.Coupex.Bot.Native");
