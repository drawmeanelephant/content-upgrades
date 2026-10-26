# Smoke test tape: dummy content only (no knap-mcp), so the video
# toolchain can be checked on its own. demo/build.sh trims two segments
# out of this take and concatenates them; the jump in the tick count
# shows where the cut landed.
Output demo/out/smoke/raw.mp4
Source demo/tapes/_settings.tape

Hide
Type "export PS1='$ '; clear"
Enter
Sleep 300ms
Show

Type "echo 'content-upgrades: video pipeline smoke test'"
Enter
Sleep 500ms
Type "for i in 1 2 3 4 5 6 7 8 9 10; do echo tick $i; sleep 0.5; done"
Enter
Sleep 6s
