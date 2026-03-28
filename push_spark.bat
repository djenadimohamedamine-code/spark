@echo off
echo --- MIMO SPARK - PUSH FINAL ---
git config --global user.email "mimo@example.com"
git config --global user.name "Mimo"
git init
git add .
git commit -m "Full Mimo Spark App - Mimo Initial Push"
git remote add origin https://github.com/djenadimohamedamine-code/spark.git
git push -u origin main --force
echo.
echo --- TERMINE ! ---
echo Si tu vois des messages d'erreur, prends une photo car la fenetre va rester ouverte.
echo Sinon, appuie sur une touche pour quitter.
pause
