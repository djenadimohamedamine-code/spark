import os
import subprocess

files_to_delete = [
    r"f:\spark\debug_push.py",
    r"f:\spark\force_push.py",
    r"f:\spark\meta_check.py",
    r"f:\spark\last_build_check.py"
]

for f in files_to_delete:
    if os.path.exists(f):
        os.remove(f)
        print(f"Deleted {f}")

os.chdir(r"f:\spark")
subprocess.run("git add .", shell=True)
subprocess.run("git commit -m \"Final_Mimo_Spark_V4_31_Complete\"", shell=True)
subprocess.run("git push", shell=True)
print("Final push complete.")
