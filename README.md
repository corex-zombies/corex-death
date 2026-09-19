# corex-death

> Death UI, respawn flow, and rag-doll physics.

Part of the [COREX Framework](https://github.com/corex-zombies).

## Install

Drop the `corex-death` folder into:
```
server-data/resources/[corex]/corex-death/
```

Load it with the matching Core and Spawn resources. The inventory provider is
optional, but item-loss penalties require its drop operation:
```cfg
ensure corex-core
ensure corex-spawn
ensure corex-death
```

## Update

Use a matching COREX update, back up your configuration and persistent data,
then merge configuration changes. Do not overwrite your server data with test
files or mix incompatible resource versions.

## Defaults and behavior

- The death countdown is 15 seconds (`Config.DeathScreen.duration`), enforced
  on the server as well as the screen.
- Item loss is off by default (`Config.Penalties.loseItems = false`). Normal
  and emergency requests share one operation so retries do not repeat penalties.
- Normal respawn uses Spawn's placement. `Config.DeathScreen.respawnCoords`
  is the last-resort local fallback, not the normal spawn configuration.
- With the matching `corex-admin`, Revive restores the player in place and
  releases Death's screen without applying item-loss penalties.
- After the countdown, click Respawn or press Enter, Space or E without
  modifiers. A background click is not a respawn request.

## Docs
[COREX documentation](https://corex-zombies.gitbook.io/corex-docs) — see Spawn,
character and death, Admin, and Troubleshooting.

## Community
💬 <https://discord.gg/G95rtnb9sg>

## License
Released under the [MIT License](LICENSE).
