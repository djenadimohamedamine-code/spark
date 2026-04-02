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
run("git add .")
run("git commit -m \"Mimo-Spark-Final-v4.31-Robust-Parsing\"")
run("git push")
run("git log -n 1 --oneline")
