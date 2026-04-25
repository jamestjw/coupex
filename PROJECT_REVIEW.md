# Project Review: Coupex

This document outlines the architectural review of the Coupex project, identifying code smells and proposing solutions to improve maintainability, scalability, and code quality.

## 1. UI Layer Complexity (LiveView Refactoring)

### **Smell: Massive Render Function**
`CoupexWeb.RoomLive` contains a `render/1` function exceeding 400 lines. It handles everything from high-level layout to granular game modal logic and conditional CSS classes.

### **Solution: Componentization**
*   **Extract Functional Components**: Move UI pieces into `CoupexWeb.GameComponents`.
    *   `<.player_seat>`: Handles avatar, coin count, and influence display for opponents.
    *   `<.action_dock>`: Manages the active player's hand and action buttons.
    *   `<.game_modal>`: A unified modal component for challenges, blocks, and exchanges.
    *   `<.chronicle>`: Dedicated component for the game log.
*   **Lean LiveView**: The LiveView should primarily orchestrate events and state. Data preparation (e.g., sorting actions) should move to `Coupex.Game.view/2` or helper functions.

---

## 3. Coupling (Context Encapsulation)

### **Smell: Direct GenServer Calls**
The LiveView layer interacts directly with `Coupex.RoomServer`. This tightly couples the web interface to the process implementation (Registry, via-tuples, etc.).

### **Solution: Context Module (The Phoenix Way)**
*   **`Coupex.Rooms` Context**: Create a module to act as the public API.
    *   `Rooms.join_room(code, player_id, name)`
    *   `Rooms.take_action(code, player_id, action, target)`
*   **Benefits**: Hides implementation details and makes it easier to change the backend (e.g., moving from a GenServer to a distributed system or database) without touching the UI code.

---

## 4. State Persistence & Reliability

### **Smell: Volatile Memory State**
Game state exists only in the `RoomServer` heap. A crash, node restart, or deployment results in immediate loss of all active games.

### **Solution: Recovery Strategy**
*   **ETS Shadowing**: Use an ETS table to store snapshots of the room state. If a `RoomServer` crashes and is restarted by its supervisor, it can hydrate its state from ETS in `init/1`.
*   **Server-Side Timers**: Move the "Auto-pass" logic from JS hooks to server-side `Process.send_after/3`. This prevents games from hanging if a player disconnects during a challenge window.

---

## 5. Defensive Programming (Type Safety)

### **Smell: Dynamic Atom Conversion**
`Validation.ensure_block_role/2` uses `String.to_existing_atom/1` on user-provided strings. While restricted to existing atoms, it’s a "magic" conversion.

### **Solution: Explicit Mapping**
*   **Translation Layer**: Use a static map to translate external string IDs (e.g., `"duke"`) to internal domain atoms (`:duke`). This makes the valid input surface explicit and easier to audit.

---

## Summary of Proposed Architecture

```text
lib/
  coupex/
    rooms.ex            # Context API (Public boundary)
    room_server.ex      # Process management & PubSub
    game/
      player.ex         # Player struct and predicate logic
      logic.ex          # Pure game rules and state transitions
      view.ex           # View-model preparation for the UI
  coupex_web/
    live/
      room_live.ex      # Lean controller for the room
    components/
      game_components.ex # Reusable functional components
```
