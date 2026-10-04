#!/usr/bin/env python3
"""SSH batch operations utility (paramiko) for VPS migration.
Usage:
  python vps.py exec <user@host> <command>        # Execute a remote command; password is read from the VPS_PASS environment variable
  python vps.py put  <local> <user@host:remote>   # Upload a file/directory (directories need to be tarred first and unpacked via exec)
  python vps.py get  <user@host:remote> <local>   # Download a file
  python vps.py shell <user@host>                 # Interactive (fallback)
"""
import os
import sys
import stat
import posixpath

import paramiko


def split_target(spec):
    userhost, _, path = spec.partition(':')
    if '@' in userhost:
        user, host = userhost.split('@', 1)
    else:
        user, host = 'root', userhost
    return user, host, path


def connect(user, host, pw):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username=user, password=pw, timeout=20)
    return c


def cmd_exec(conn, command, echo=True):
    stdin, stdout, stderr = conn.exec_command(command, get_pty=True)
    out = b''
    while True:
        line = stdout.readline()
        if not line:
            break
        if isinstance(line, str):
            line = line.encode()
        out += line
        if echo:
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
    err = stderr.read()
    if isinstance(err, str):
        err = err.encode()
    if echo and err:
        sys.stderr.buffer.write(err)
        sys.stderr.buffer.flush()
    rc = stdout.channel.recv_exit_status()
    return rc, out + err


def sftp_put(conn, local, remote):
    sftp = conn.open_sftp()
    if os.path.isdir(local):
        sftp.mkdir(remote)
        for name in os.listdir(local):
            lp = os.path.join(local, name)
            rp = posixpath.join(remote, name)
            if os.path.isdir(lp):
                sftp_put(conn, lp, rp)
            else:
                print(f'  put {lp} -> {rp}')
                sftp.put(lp, rp)
    else:
        print(f'put {local} -> {remote}')
        sftp.put(local, remote)
    sftp.close()


def sftp_get(conn, remote, local):
    sftp = conn.open_sftp()
    print(f'get {remote} -> {local}')
    sftp.get(remote, local)
    sftp.close()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    action = sys.argv[1]
    pw = os.environ.get('VPS_PASS', '')
    if action == 'exec':
        target, command = sys.argv[2], sys.argv[3]
        user, host, _ = split_target(target)
        conn = connect(user, host, pw)
        rc, _ = cmd_exec(conn, command)
        conn.close()
        sys.exit(rc)
    elif action == 'put':
        local, target = sys.argv[2], sys.argv[3]
        user, host, remote = split_target(target)
        conn = connect(user, host, pw)
        sftp_put(conn, local, remote)
        conn.close()
    elif action == 'get':
        target, local = sys.argv[2], sys.argv[3]
        user, host, remote = split_target(target)
        conn = connect(user, host, pw)
        sftp_get(conn, remote, local)
        conn.close()
    elif action == 'shell':
        user, host, _ = split_target(sys.argv[2])
        conn = connect(user, host, pw)
        chan = conn.invoke_shell()
        import threading

        def reader():
            while True:
                data = chan.recv(1024)
                if not data:
                    break
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()

        t = threading.Thread(target=reader, daemon=True)
        t.start()
        try:
            while True:
                line = sys.stdin.readline()
                if not line:
                    break
                chan.send(line)
        except KeyboardInterrupt:
            pass
        conn.close()


if __name__ == '__main__':
    main()
