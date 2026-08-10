# bcc-hunting-wagon

Hunter Cart feature package for `bcc-wagons`.

## Responsibilities

- Carcass load and unload prompts
- Cargo menu with animal names, quality, skinned state, capacity, and selective unloading
- Persistent carcass cargo
- Quality and skinned-state restoration
- Hunter Cart tarp presentation
- Transaction-safe server exports for butcher integrations
- Hunting-specific configuration and database schema

## Dependencies

- `bcc-wagons`
- `bcc-animal-data`
- `bcc-utils`
- `vorp_core`
- `oxmysql`

Start this resource after its dependencies and import `database/schema.sql`.

## Player flow

Carry a dead animal to the rear of an owned Hunter Cart to load it. When the
cart contains cargo, use the rear unload prompt to open the cargo menu. Cargo
can be reviewed and unloaded individually.

## Butcher integration

The server API lets a butcher resource inspect and transactionally consume
cargo without reading this resource's database directly.

```lua
exports['bcc-hunting-wagon']:GetButcherCargo(source, wagonId, callback)
exports['bcc-hunting-wagon']:ReserveButcherCargo(source, wagonId, cargoIds, callback)
exports['bcc-hunting-wagon']:FinalizeButcherCargo(token, consumed, callback)
```

`ReserveButcherCargo` removes the selected rows temporarily and returns a
token plus the reserved items. Call `FinalizeButcherCargo` with `true` only
after payment succeeds. Passing `false`, allowing the reservation to time out,
or stopping the calling resource restores the cargo.
