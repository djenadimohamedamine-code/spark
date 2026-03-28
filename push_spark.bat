@echo off
echo --- PUSH & BUILD MIMO_SPARK ---
git add .
git commit -m "Mimo Spark: UI Fix, Menu Lateral and Dashboard Optimization"
git push
echo.
echo Le build a demarre sur GitHub Actions ! 
echo Appuie sur une touche pour quitter et verifier ton navigateur.
pause
