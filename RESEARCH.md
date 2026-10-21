# Disk cleaner for Mac: market research and plan

Working name: **Ebb** or **Sweepr**, still to be decided. Research done on 2026-10-21.
Items marked *(unverified)* came from secondary sources or could not be confirmed.

## The pitch

A free, open-source, native Mac app that shows what is filling your disk, including the developer junk other tools miss. It labels each finding as **safe**, **review** or **careful** and explains why. Cleaning moves files to the Trash instead of deleting them.

## Why it's worth building

On one developer MacBook, a one-minute read-only scan of common locations found about 118 GB of candidates:

| Location | Size | Verdict |
|---|---|---|
| Docker Desktop data | 71.2 GB | careful: volumes can hold databases, so use `docker system prune` |
| npm cache (`~/.npm`) | 13.8 GB | safe |
| `~/Library/Caches` | 11.3 GB | mostly safe |
| conda package cache | 7.9 GB | safe with `conda clean -a` |
| `~/.cache` (pip, downloaded models…) | 6.9 GB | review |
| Cursor/VS Code cached data | 2.6 GB | safe |
| `node_modules` in old projects (top 5 only) | ≥ 3.7 GB | review, can be reinstalled |

The safe items alone add up to about 36 GB.

## Competitors

| App | Price / licence | Strength | Weakness |
|---|---|---|---|
| **tw93/Mole** | Free CLI, GPL-3.0, ~72k ★ | Huge traction. Cleans, uninstalls apps, analyses disks, finds dev artefacts (`mo purge`). Protects git-tracked and recently used files. | CLI only, and deletes permanently once you confirm. The authors now sell a separate proprietary GUI app. |
| Pearcleaner | Source-available (Apache 2 + Commons Clause), ~14k ★ | App uninstaller and leftover finder | Not a disk analyser |
| npkill | Free CLI, ~9.3k ★ | Finds and deletes `node_modules` | Only does `node_modules` |
| DevCleaner for Xcode | Mac App Store | Covers Xcode DerivedData and simulators | Xcode only |
| DaisyDisk | ~$9.99 one-time | Best-looking sunburst chart | Paid, and blind to dev junk |
| CleanMyMac | ~$35–40/yr | Polished all-in-one | Users push back on the subscription and the "scareware" feel |
| GrandPerspective | Free, open source | Treemap | Dated UI |
| OmniDiskSweeper, Disk Inventory X | Free | Simple size list or treemap | Basic; Disk Inventory X is unmaintained |
| macOS Storage settings | Built in | Free | Lumps everything into "System Data" and can't drill into dev junk |
| TidyDisk, FreeUp, BroomKit, Untainted… | Mixed | Similar ideas (risk tiers, Trash) | Little visible traction *(unverified)* |

**The gap.** Mole's ~72k stars prove the demand, but it is a CLI, and the only GUI from its authors is proprietary. Nobody yet offers a **polished, genuinely free and open-source GUI that understands developer junk**. The small GUI newcomers have no traction, so winning comes down to trust and polish.

## What users struggle with
Evidence here is thinner and mostly comes from forums and vendor write-ups.
- **"System Data" is a black box.** It usually hides Time Machine local snapshots (purgeable space, which is why Finder and `df` disagree), Xcode DerivedData, simulators, old iOS backups and Docker.
- **Simulator runtimes linger.** One Apple forum report describes about 33 GB of simulator images left behind after uninstalling Xcode that could not be deleted.
- **Fear and distrust.** People are afraid of deleting the wrong thing, don't trust "cleaner" apps, and are tired of subscriptions.

**Real voices from Hacker News.** Reddit couldn't be reached from the research environment.
- *Show HN: Cleano, a Mac App Store cleaner for developers (2024)*:
  - "To potentially save you the click, the app is a subscription service."
  - "I hate the dark patterns to sell this subscription."
  - "Does this do more than simple bash script would?"
  - "I already have DevCleaner and DaisyDisk… but what I really need is a 2TB MBP."
  - https://news.ycombinator.com/item?id=40382941
- *Show HN: Clean Your Mac with a Script (2024)*. The author built it to avoid "a shady paid app".
  - Safety critique: "Deleting individual files from ~/Library/Caches based only on their mtime is not safe."
  - After running it: "'System Data' still takes up an insane amount of my disk space."
  - Root cause: "Way too much software uses the user's filesystem as their personal dumping ground."
  - https://news.ycombinator.com/item?id=42250429

**Takeaways.** Be genuinely free with no upsell. Act on whole folders or through each tool's official command, never by guessing from file dates. Make "System Data" explainable. Prove value a bash script can't: visuals, explanations, safety and undo.

Needs nobody meets well yet:
1. A free tool that **explains** each item and why it is safe to remove.
2. A dev-aware **GUI**.
3. Honest reclaimable-space numbers that account for clones, snapshots and sparse files.
4. Undo.

## Feature plan

**MVP (must-haves)**
- Fast full-disk scan with a beautiful treemap or sunburst.
- Developer junk detectors, each with a safe/review/careful label and a plain-English explanation:
  - package-manager caches: npm, yarn, pnpm, pip, conda, Homebrew
  - Docker
  - Xcode DerivedData, simulators and device support
  - Gradle and Cargo
  - IDE caches
  - stale `node_modules`, `target` and `.build` folders
- "Large and old files" view (for example over 500 MB and untouched for 6 months), presented as a hint.
- Trash by default, with a running "reclaimable / in Trash" counter and an undo history.
- A dry-run summary before anything changes.
- Official cleanup commands where they exist instead of raw deletes.
- Protection for git-tracked files and anything modified in the last 7 days, as Mole does.
- No network and no telemetry, stated clearly.
- Distributed as a DMG and a Homebrew cask, like Islet.

**Later (nice-to-haves)**
- "Disk almost full" peek in [Islet](https://github.com/ZNLong2203/Islet).
- Menu bar disk monitor.
- Duplicate finder.
- CLI companion.
- Time Machine local snapshot thinning.

## Technical notes
- **Scanning.** `getattrlistbulk` is the fast path because it batches attributes per directory. The `FileManager` enumerator with `.totalFileAllocatedSizeKey` is simpler but slower. Parallelise per top-level folder and cache the results.
- **APFS sizes.**
  - Use the *allocated* size, so sparse files such as `Docker.raw` aren't overstated.
  - Clones report their full size per file, so naive totals overcount.
  - Dedupe hard links by inode.
  - Snapshots and purgeable space explain why Finder and `df` disagree. Use `tmutil listlocalsnapshots /` to see them.
  - Check how `ATTR_FILE_ALLOCSIZE` behaves with clones *(unverified)*.
- **Full Disk Access.** It is needed for protected folders. Detect it by trying to read a protected path, then deep-link to System Settings. This is also why the app can't ship on the Mac App Store, because sandboxed apps can't scan the whole disk.
- **Last-opened dates.** `kMDItemLastUsedDate` is unreliable. Many files never get a value, and quarantined files may not update. Fall back to access and modification times, treat the result as a hint, label it "review", and check git activity for project folders.
- **Official cleanup commands:**
  - `docker system prune` (add `-a --volumes` only behind an explicit warning)
  - `conda clean -a`
  - `npm cache clean --force`
  - `pnpm store prune`
  - `yarn cache clean`
  - `brew cleanup`
  - `xcrun simctl delete unavailable`
  - `cargo clean` (per project)
- **Trash caveat.** Moving files to the Trash doesn't free space until the Trash is emptied, so the UI must say so.

## Name candidates

| Name | Homebrew | GitHub | Notes |
|---|---|---|---|
| **Ebb** | free | unrelated "EBB" (3D-printer board) | Matches Islet's sea theme: the tide goes out and shows what's underneath |
| **Sweepr** | free | nothing relevant | Says exactly what it does |
| Dustoff | free | `westpoint-io/dustoff` (52 ★) | Name collision, so avoid |
| Mopup, Gravel | free | unrelated repos | Weaker fit |
| Scour | **taken** (formula) | — | Avoid |

## Sources
- https://github.com/tw93/mole and https://openalternative.co/mole
- https://github.com/alienator88/Pearcleaner
- https://www.star-history.com/voidcosmos/npkill
- https://apps.apple.com/app/id1388020431 (DevCleaner for Xcode)
- https://formulae.brew.sh/cask/omnidisksweeper
- https://macpaw.com/insights/mac-storage-junk-explained (vendor source, may be biased)
- https://www.kodeco.com/19998365-understanding-and-managing-xcode-space
- https://developer.apple.com/forums/thread/797098 (simulator leftovers)
- https://developer.apple.com/forums/thread/807142 (sandbox and Full Disk Access)
- https://developer.apple.com/forums/thread/129646 and /thread/20639 (`kMDItemLastUsedDate`)
- https://github.com/prateekcode/tidydisk
- https://docs.rs/crate/diskr/latest
