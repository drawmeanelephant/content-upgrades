# One genuine Baseten call. The typed credential is an invented, unexecuted gag.
# KNAP_DEMO_KEY_FILE is a private secret-workflow path, never an on-screen argument.
# KNAP_BASETEN_TAKE_DIR must be a fresh directory for the public take and receipt.
Output demo/out/tapes/02-baseten-live.mp4
Require python3
Require glow
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh && export HISTFILE=/dev/null && ln -s $DEMO_ROOT/demo/baseten_take.py baseten_take.py"
Enter
Sleep 300ms
Show

Type@70ms `export MODEL_API_KEY="absolutely_not_on_camera_`
Sleep 400ms
Ctrl+U
Type `echo "Nice try. Not on camera."`
Enter
Sleep 900ms

Type "python3 baseten_take.py"
Enter
Wait+Screen@120s /BASE TEN_TAKE_(READY|FAILED)/
Sleep 3s

Type "glow -p baseten.md"
Enter
Sleep 6s
