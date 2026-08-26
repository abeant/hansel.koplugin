# Hansel

KOReader starts in your Grimmory library.

You have a device with space. You would rather not live in the vendor reader. Install [KOReader](https://koreader.rocks/), sign Hansel into [Grimmory](https://grimmory.org), tap a cover. Downloads stay on the device. You do not keep a second file tree.

<!-- screenshots: drop images in docs/screens and uncomment
<p align="center">
  <img src="docs/screens/home.png" width="240" alt="Cover grid">
  <img src="docs/screens/drawer.png" width="240" alt="Library drawer">
  <img src="docs/screens/detail.png" width="240" alt="Book detail">
</p>
-->

Requires KOReader 2024.12+. Works anywhere KOReader runs plugins (Android, Kindle, Kobo).

## Install

Copy `hansel.koplugin` into KOReader’s `plugins` folder, restart, enable **Hansel** under Tools → Plugin management, then:

**File Manager → Settings → Start with → hansel**

Restart once more. From a book, assign **Show Hansel** in Gesture Manager.

Also listed in the [KOReader App Store](https://github.com/omer-faruq/appstore.koplugin) once the repo is public (`koreader-plugin` topic).

## Sign in

Server URL, Grimmory username, password. After that you can turn on Auto sync so progress follows you.

## Settings

- **Start with** - KOReader boots into the cover grid instead of File Manager.
- **Auto sync** - after account login, progress follows you (percent + XPointer). Off until you turn it on. Stands down if the official Grimmory plugin is already syncing.
- **Hide unavailable books** - when this device can’t reach Grimmory, only show books already on it.
- **On this device** - drawer row. Same list, on purpose.
- **Pin** - keep a downloaded book when you would otherwise evict it.

## Why this exists

KOReader can already add Grimmory over OPDS. That is a catalog you visit, then a file you find again in File Manager. Hansel signs in and the cover grid is the library.

Not the official Grimmory plugin. If [`grimmory.koplugin`](https://github.com/grimmory-tools/grimmory.koplugin) is already syncing, Hansel leaves that alone.

## License

[AGPL-3.0](LICENSE). Not affiliated with Grimmory.

Designed with AI assistance. The plugin is reviewed and tested as a normal KOReader project.
