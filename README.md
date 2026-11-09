# Surveillance Morali Pay

Robot externe : toutes les 5 minutes, depuis les serveurs de GitHub (pas ceux du site), il vérifie que
moralipay.com répond, que la base de données est joignable et que les fichiers de l'app se chargent
(sinon les clients verraient un écran blanc après une mise à jour). En cas de panne, il envoie une alerte
Telegram, un rappel toutes les 30 minutes, puis un message quand le site revient.

Secrets requis (Settings → Secrets and variables → Actions) : `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`.

Test manuel : onglet Actions → « Surveillance Morali Pay » → Run workflow.
