# Coupex

**Coupex** is a real-time, web-based implementation of the popular social deduction board game *Coup*. Built with Elixir and Phoenix LiveView, it offers a seamless, interactive "parlor game" experience directly in the browser without the need for card-handling or manual bookkeeping.

## 🃏 The Game

Coup is a game of deception, deduction, and power. Each player starts with two hidden "influences" (cards) and two coins. The goal is to be the last player with remaining influence.

### Key Features
- **Real-time Multiplayer**: Powered by Phoenix LiveView for instant state synchronization across all players.
- **Room System**: Create private rooms with 6-character codes to play with friends (2–6 players supported).
- **Full Ruleset**:
  - **Character Actions**: Duke (Tax), Assassin (Assassinate), Captain (Steal), Ambassador (Exchange).
  - **Standard Actions**: Income, Foreign Aid, Coup.
  - **Interactions**: Challenge bluffs, block actions (Contessa, Duke, Captain, Ambassador).
- **The Chronicle**: A live, detailed game log that tracks every move, challenge, and loss of influence.
- **Modern UI**: A rich, "dark parlor" aesthetic with responsive design for desktop and mobile play.

## 🛠️ Getting Started

### Prerequisites
- Elixir 1.15+
- Erlang/OTP 26+
- Node.js (for asset compilation)

### Setup
1. **Clone the repository**:
   ```bash
   git clone https://github.com/jamestjw/coupex.git
   cd coupex
   ```

2. **Install dependencies**:
   ```bash
   mix setup
   ```

3. **Start the server**:
   ```bash
   mix phx.server
   ```

4. **Play**:
   Open `http://localhost:4000` in your browser. Open multiple tabs or different browsers to simulate multiple players.

## 🧪 Testing & Quality

Coupex maintains a robust test suite covering core game logic and room synchronization.

- **Run all tests**:
  ```bash
  mix test
  ```
- **Pre-commit Check**:
  Run the full quality suite (compile with warnings-as-errors, format check, and tests):
  ```bash
  mix precommit
  ```

## 📂 Project Structure

- `lib/coupex/game.ex`: The core, pure functional game engine.
- `lib/coupex/room_server.ex`: GenServer managing room state and player connections.
- `lib/coupex_web/live/room_live.ex`: The real-time UI layer.
- `lib/coupex/game/validation.ex`: Rule enforcement and validation logic.

## 📜 License

This project is open-source and available under the [MIT License](LICENSE).
