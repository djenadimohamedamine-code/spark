@echo off
echo --- PUSH & BUILD MIMO_SPARK V4.31 ---
git add .
git commit -m "Mimo Spark: Robust Parsing & Elite Init"
git push
echo.
echo Le build a demarre sur GitHub Actions ! 
echo.
pause
