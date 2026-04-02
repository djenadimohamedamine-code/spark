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
run("git status")
run("git log -n 1 --oneline")
run("git add .")
run("git commit -m \"PRO-Parsing Fix\"")
run("git push")
