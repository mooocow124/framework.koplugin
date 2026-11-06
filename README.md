# Framework Mode for KOReader

Allows using KOReader as an application framework for devices like Kobo or Kindle.

For Kindle, I'd recommend launching KOReader with --asap when using this framework to make it faster to load.

KOReader home screen is still visible for a tiny bit when using this, this is pre-`wontfix` because it'll be a PITA to fix. If you'd like to make a PR fixing this, go ahead, I'll review and merge it.

In a nutshell, when this plugin is installed and KOReader is launched with `--fwlaunch="name of tool"`, KOReader will immediately launch that tool and commit suicide when the tool closes!

I've tested this with `ink-away.koplugin`, `boardgames.koplugin`, `storefront.koplugin`, plus built-in KOReader cloud storage menu.

Meant to be used with plugin whitelist from [this userpatch](https://gist.github.com/mooocow124/c9bf5de5e21370c032f3e019547d1a4e).