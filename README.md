# XARLI0's Grab Hub

A Roblox script for **Jujutsu Shenanigans (JJS)**. It teleports you onto a target of your choice when you use a grab move, then sends you back to where you started.

## How it works

1. Pick a target in the **Target** tab (any player or dummy in the server, with a search box that forgives typos).
2. Press the ability key. Your position is saved.
3. The script teleports you to the target as the grab lands, then returns you to your saved spot.

## Supported moves

| Move | Character | Key |
|------|-----------|-----|
| Swift Kick | Todo | 1 |
| Cursed Strikes | Vessel / Yuji | 1 |
| Rapid Punches | Gojo | Coming soon |

Each move only reacts while you are playing its character, and can be switched on or off in the **Main** tab.

## Usage

Run this in your executor while in the game:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/XARLI0/XARLI0sGrabHub/main/XARLI0_GrabHub.lua"))()
```

Press **RightShift** to hide or show the menu. The **Destroy script** button removes everything cleanly.

The UI is built with [WindUI](https://github.com/Footagesus/WindUI).

## Disclaimer

Use at your own risk. This project is not affiliated with Roblox or the game's developers.
