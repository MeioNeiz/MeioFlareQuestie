# Meio FlareQuestie

Questie's quest data in FlareUI's quest tracker: how far each quest is and who to hand it in to.

![FlareUI's quest tracker with four quests in Duskwood: before, only the objectives and "Ready for turn-in"; with MeioFlareQuestie, yards to each quest and "Return to Lord Ello Ebonlocke"](docs/before-after.png)

## What it does

[FlareUI](https://www.curseforge.com/projects/1718307) keeps the look,
[Questie](https://www.curseforge.com/projects/334372) supplies where things are.

- Yards to each quest, the nearest in white; FlareUI's Sort: Distance orders by them
- "Return to" the turn-in NPC on finished quests, and Questie's quest items as buttons
- Quest tooltips: the nearest objective or turn-in, with yards and direction
- Show on Map (or Alt-click a quest) flashes the quest's Questie icons
- Search: the magnifier in the header lists only the quests that match

The quest count turns orange at 2 free log slots and red when the log is full. Drag the
grip in the tracker's free corner to resize it.

Settings: Esc > Options > AddOns > MeioFlareQuestie

- `/flarequestie`: settings
- `/flarequestie help`: the list of commands
- `/flarequestie status`: what Questie finds for your quests, and whether FlareUI is patched
- `/flarequestie distance on|off`: yards to each quest
- `/flarequestie compact on|off`: tighter tracker spacing
- `/flarequestie fonts small|default`: smaller tracker text, or FlareUI's
- `/flarequestie size reset`: FlareUI's default tracker size
- `/flarequestie search <text>`: the same as the magnifier

## Install

Needs FlareUI with its quest tracker on, and Questie (without it, only resizing and compact
spacing work).

FlareUI's tracker has no way for another addon to plug in, so most of MeioFlareQuestie needs
three small FlareUI patches. Without them it says so at login.

1. Install PowerShell 7: `winget install Microsoft.PowerShell`
2. Download this repository (**Code** > **Download ZIP**) and extract it
3. Close WoW, open a terminal in that folder and run
   `pwsh -ExecutionPolicy Bypass -File mods.ps1`
   (WoW elsewhere: add `-AddOns "<your>\_forever_\Interface\AddOns"`)

It copies the addon and patches `FlareUI\Modules\ObjectiveTracker.lua`, keeping a backup in
`backups\`. Each patch in `patches\` shows the old and new lines. A FlareUI update undoes
them: run it again (`mods.ps1 status` checks without changing anything).
Without MeioFlareQuestie the patched tracker works exactly like FlareUI's own.

## Feedback

Bugs and ideas: [GitHub issues](https://github.com/MeioNeiz/MeioFlareQuestie/issues)

## More Meio addons

[Meio TrainerCompare](https://www.curseforge.com/wow/addons/trainercompare) | [Meio Next Stop](https://www.curseforge.com/wow/addons/leavebutton) | [Meio AutoRank](https://www.curseforge.com/wow/addons/meio-autorank) | [Meio MeterHover](https://www.curseforge.com/wow/addons/meterhover) | [Meio Map](https://addons.wago.io/addons/meiomap) | [Meio Alts](https://addons.wago.io/addons/meioalts) | [Meio DPS](https://addons.wago.io/addons/meiodps) | [Meio Plates](https://addons.wago.io/addons/meioplates) | [Meio Hub](https://addons.wago.io/addons/meiohub) | [Meio Pets](https://addons.wago.io/addons/meiopets) | [Meio Stats](https://addons.wago.io/addons/meiostats) | [Meio Bags](https://addons.wago.io/addons/meiobags) | [Meio Fixes](https://addons.wago.io/addons/meiofixes) | [Meio Flight Times](https://addons.wago.io/addons/meioflighttimes) | [Meio Mail](https://addons.wago.io/addons/meiomail) | [Meio Auto Run Turn](https://www.curseforge.com/wow/addons/meio-auto-run-turn) | [Meio TSM Browse](https://addons.wago.io/addons/tsmbrowse)

## Licence

[MIT](LICENSE)
