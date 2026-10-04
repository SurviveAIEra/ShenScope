function terminal_fixture(root;owner="terminal-owner",process=Allow,read=Allow,approve=request->:deny,sandbox=ShenScope.HostSandbox())
    RuntimeContext(root;session_id=owner,state_dir=joinpath(root,"state"),sandbox,approve,
        permissions=PermissionPolicy(;rules=Dict(:process=>process,:read=>read,:persistence=>Deny,:network=>Deny,:dynamic=>Deny)))
end
function terminal_await_output(handle,needle;seconds=20)
    timedwait(()->occursin(needle,terminal_page(handle.journal)["text"]),seconds;pollint=0.01)==:ok
end

const TERMINAL_PYTHON = Sys.which("python3")
const TERMINAL_ECHO_PROGRAM = """
import os, sys, termios, signal, struct, fcntl
assert all(os.isatty(fd) for fd in (0,1,2))
assert os.tcgetpgrp(0) == os.getpgrp()
print('TTY_READY', fcntl.ioctl(0, termios.TIOCGWINSZ, bytes(8)).hex(), flush=True)
def resized(*_):
    print('RESIZED', fcntl.ioctl(0, termios.TIOCGWINSZ, bytes(8)).hex(), flush=True)
signal.signal(signal.SIGWINCH, resized)
for line in sys.stdin:
    print('ECHO:' + line.strip(), flush=True)
    if line.strip() == 'exit': break
"""
