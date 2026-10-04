"""Close every inherited non-stdio descriptor before starting trusted Julia.

This is a narrow exec launcher, not the agent or an evaluation sandbox. Julia
installs the synchronized seccomp profile before accepting candidate source.
"""
import os
import sys
import errno


def main():
    arguments = sys.argv[1:]
    if not arguments or not os.path.isabs(arguments[0]):
        return 1
    try:
        # Inspect first, close the directory iterator, then close descriptors.
        # Existing descriptors may exceed a subsequently lowered RLIMIT_NOFILE.
        with os.scandir('/proc/self/fd') as entries:
            descriptors = [int(entry.name) for entry in entries if entry.name.isdecimal()]
        for descriptor in descriptors:
            if descriptor > 2:
                try:
                    os.close(descriptor)
                except OSError as cause:
                    if cause.errno != errno.EBADF:
                        return 1
                    # The scandir descriptor is already closed.
        os.execve(arguments[0], arguments, dict(os.environ))
    except OSError:
        return 1
    return 1


if __name__ == '__main__':
    sys.exit(main())
