# pastethrough

Press Ctrl+V in Claude Code on a remote host and paste the image from your Mac clipboard.

Claude Code on Linux reads clipboard images by shelling out to `xclip`. Over SSH there is
no display, so it fails and prints `No image found in clipboard. You're SSH'd; try scp?`.
This replaces `xclip` on the remote with a shim that reads your Mac clipboard instead.

```
  Mac                                        remote
  ---                                        ------
  launchd: socat -> clip-png                 ~/.local/bin/xclip   (shim)
     listens 127.0.0.1:5556                        ^
              |                                    |
  launchd: ssh -N -R 5556:localhost:5556 ---> 127.0.0.1:5556
     KeepAlive, restarts on drop                   ^
                                                   |
                              tmux / argus session -+--> claude --> Ctrl+V
                              plain ssh login shell -+
```

The tunnel is always on, so anything on the remote can paste: an interactive shell, a tmux
pane, or an agent supervisor such as argus that spawns Claude for you.

## Install

```sh
brew install socat
./install.sh myhost
```

`myhost` is any name your `~/.ssh/config` resolves. Key auth must already work without a
password. The installer sets up the Mac side, the tunnel, and the remote shim, then runs
the checks.

```sh
./install.sh --check myhost      # verify end to end
./install.sh --uninstall myhost  # remove everything
```

## Use

```
  ssh myhost
  claude
  Cmd+Shift+4 on the Mac, then Ctrl+V
  > describe this [Image #1]
```

Use **Ctrl+V**, not Cmd+V. Your terminal owns Cmd+V and pastes text, so Claude Code never
sees an image. Claude Code binds image paste to `ctrl+v` on macOS and Linux, and to
`alt+v` on Windows and WSL.

## How it works

Claude Code runs exactly two commands to paste an image on Linux:

```
xclip -selection clipboard -t TARGETS   -o
xclip -selection clipboard -t image/png -o
```

The shim answers both by reading one TCP connection on port 5556. On the Mac, `socat`
serves that port and runs `clip-png` per connection, which coerces the clipboard to PNG
with `osascript`. Nothing is cached and no daemon holds clipboard state.

Every other `xclip` call falls through to the real binary, and so does any call made while
the tunnel is down. Installing this does not break `xclip` on the remote.

## Requirements and limits

- The client must be macOS. It uses `osascript` and launchd.
- The remote must be Linux with `bash`, for `/dev/tcp`.
- `~/.local/bin` must come before `/usr/bin` in the remote PATH. The installer warns if it
  does not. Check the PATH of whatever spawns Claude, not only your login shell; a
  supervisor started from a different environment can have a different PATH.
- Port 5556 is fixed unless you set `PASTETHROUGH_PORT`. It must be free on both ends.
- One clipboard source only: the Mac running the tunnel. A phone or a second client
  connected to the same remote still sees the Mac clipboard.
- The remote listener binds to loopback, so only processes on the remote can read it.
  Anything that can run code there can read your clipboard on demand.

## Prior art

Several projects solve the same problem, some with more platform coverage:
[cc-clip](https://github.com/ShunmeiCho/cc-clip),
[clipaste](https://github.com/hqhq1025/clipaste),
[clipfan](https://github.com/prime-radiant-inc/clipfan),
[clipssh](https://github.com/samuellawrentz/clipssh).

[anthropics/claude-code#42712](https://github.com/anthropics/claude-code/issues/42712) asks
for OSC 52 and OSC 5522 clipboard support. If that ships, none of this is needed.
