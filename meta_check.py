import subprocess
import os

def run(cmd):
    print(f"--- RUN: {cmd} ---")
    try:
        res = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT)
        print(res.decode('utf-8'))
    except subprocess.CalledProcessError as e:
        print(f"FAIL: {e.output.decode('utf-8')}")

os.chdir("f:\\spark")
run("git show 53a468f")
run("git show 14a1b8a")
run("git show 91e0053")
