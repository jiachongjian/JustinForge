# JustinForge

Justin Chia's World of Warcraft Addon

## Overview

JustinForge is a collection of independent quality-of-life features for World of Warcraft (Retail, patch 12.0.7, compatible with 12.1). Each feature is a self-contained module with its own enable/disable toggle, accessible through a native settings panel under **Game Options → AddOns**.

- **No third-party dependencies** — built entirely with native Lua and Blizzard's Settings API
- **Modular architecture** — adding a new feature requires only one new file and one registration line
- **Zero-overhead when disabled** — disabled modules unregister all events and hooks
- **Native UI consistency** — settings panel uses the standard Blizzard Settings framework

## Features

| # | Module | Description |
|---|--------|-------------|
| 1 | Guild Cloak Auto-Restore | Automatically swaps the back slot back to the previous item after equipping a guild cloak |
| 2 | Map Window Center | Repositions the world map window to screen center each time it opens |
| 3 | Merchant Window Expand | Expands the merchant frame from 10 to 20 items per page, preserving the original layout direction |

## Installation

1. Copy the `JustinForge` folder into your WoW `AddOns` directory (`_retail_/Interface/AddOns/`)
2. Launch the game and log in
3. Open **Game Menu → Options → AddOns** and find the **JustinForge** category
4. Toggle individual features on or off as desired

## Project Structure

```
JustinForge/
├── JustinForge.toc          # Addon metadata, load order, SavedVariables
├── Core/
│   ├── Init.lua             # Namespace, default config, ADDON_LOADED handler
│   ├── Util.lua             # Shared helpers (Print, Debug, item ID extraction)
│   ├── Module.lua           # Module registry (Register/Enable/Disable)
│   └── Config.lua           # Native Settings API panel with per-module checkboxes
├── Modules/
│   ├── GuildCloak.lua       # Feature 1: guild cloak auto-restore
│   ├── MapCenter.lua         # Feature 2: map window centering
│   └── MerchantExpand.lua   # Feature 3: merchant window expansion
└── Locales/
    └── zhCN.lua              # Simplified Chinese localization
```

## Configuration

All settings are persisted via `SavedVariables` (`JustinForgeDB`) and automatically restored on the next login. The structure is:

```lua
JustinForgeDB = {
    profile = {
        guildCloak     = { enabled = true },
        mapCenter      = { enabled = true },
        merchantExpand = { enabled = true },
    }
}
```

## Adding a New Feature

1. Create a new file under `Modules/` (e.g. `MyFeature.lua`)
2. Register the module with `ns.Module:Register({ key = "myFeature", ... })`
3. Implement `module:OnEnable()` and `module:OnDisable()`
4. Add a default entry in `Core/Init.lua` (`myFeature = { enabled = true }`)
5. Add localization strings in `Locales/zhCN.lua`
6. Add the file path to `JustinForge.toc`

The settings panel will automatically display a new checkbox for the feature — no changes to `Config.lua` are needed.

## Compatibility

- **Interface:** `120007` (patch 12.0.7). Update to `120100` when 12.1 goes live.
- **Localization:** Simplified Chinese (`zhCN`) only. Additional locales can be added under `Locales/`.

## License

See [LICENSE](LICENSE) for details.
