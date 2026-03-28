@echo off
echo --- MIMO SPARK - PUSH FINAL (ULTIME) ---
git config --global user.email "mimo@example.com"
git config --global user.name "Mimo"
git init
git branch -M main
git remote remove origin
git remote add origin https://github.com/djenadimohamedamine-code/spark.git
git add .
git commit -m "Mimo Spark First Commit"
git push -u origin main --force
echo.
echo --- SUCCESS ! ---
echo Verifie GitHub maintenant.
pause
