@echo off
rem install.bat - equivalent Windows de install.sh pour __APP_NAME__ (poste d'un developpeur).
rem Le lab ne le joue jamais (il tourne sous Linux) : il doit faire la meme chose qu'install.sh.
rem   install.bat           fait ce qui manque (idempotent)
rem   install.bat --check   ne modifie rien, dit ce qui manque (code 1 s'il manque quelque chose)
rem Memes regles qu'install.sh : pas de droits administrateur, aucun secret ecrit ici.
setlocal
set CHECK=0
if "%~1"=="--check" set CHECK=1
if not "%~1"=="" if not "%~1"=="--check" (echo usage : install.bat [--check] & exit /b 2)
set MISSING=0
rem Exemple :
rem if not exist data\cache ( if %CHECK%==1 (echo manque : data\cache & set MISSING=1) else (mkdir data\cache) )
if %MISSING%==0 echo rien a faire
exit /b %MISSING%
