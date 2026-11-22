// Renvoie le retour de connexion (code et state) à l'application Android « Coffre du lab ».
// Le code n'a de valeur qu'avec le secret PKCE que seule l'application détient.
(function () {
  var q = window.location.search;
  var lien = document.getElementById('ouvrir');
  lien.href = 'intent://' + window.location.host + '/coffre-retour/' + q +
    '#Intent;scheme=https;package=io.github.sacha37420.coffre;end';
  // Le code ne reste pas dans l'historique du navigateur.
  history.replaceState(null, '', '/coffre-retour/');
})();
