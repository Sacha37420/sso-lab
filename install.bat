@echo off
rem install.bat - le lab ne s'installe pas sous Windows.
rem
rem Le lab exige un hote Linux : demon Docker de l'hote (socket monte par le moteur), pare-feu
rem iptables des espaces de travail, cron (sauvegardes, taches de nuit), ports 80/443 de la machine.
rem WSL2 n'est pas eprouve pour cela (decision du chantier modules, 2026-11-14).
rem
rem Sur une machine Linux (Debian 13 eprouvee) :  bash scripts/install.sh --check
rem Un module (app) peut fournir son propre install.bat pour un poste de developpeur :
rem voir modules/README.md.
echo Le lab ne s'installe pas sous Windows : il faut un hote Linux avec Docker.
echo Sur cet hote : bash scripts/install.sh --check   (voir README.md, section 1)
exit /b 1
