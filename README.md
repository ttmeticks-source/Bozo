### How to use this:
1. create a new public repository on GitHub named `bozo-executer`.
2. upload the four files above into the root of the repo (except `main.m`, `dylib.m`, and `bridge.lua` which go in the `src/` folder).
3. replace `yourusername` in the `install.sh` and `README.md` with your actual GitHub username.
4. anyone can now run `curl -sL https://raw.githubusercontent.com/ttmeticks/Bozo/main/install.sh | bash` and it will download, compile, and run the app on their Mac.

**note:** because macOS's `task_for_pid` is heavily restricted, the injection script above will likely fail on launch. The `install.sh` uses `sudo` to give it the best chance, but if the app crashes with a "Segmentation Fault," it means macOS blocked the memory access. This is a hard limit of macOS, not a bug in the code.
