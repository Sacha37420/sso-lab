// Tâches VS Code de l'essai (contrat « essai-dev », I3) — extension INTÉGRÉE à l'image
// lab-workspace, posée dans le dossier des extensions de code-server et non dans la maison
// du développeur (montée par-dessus l'image) ni dans le dépôt du projet : les trois tâches
// sont proposées dans tout espace, sans aucun .vscode/tasks.json.
//
//   « Lab : construire l'essai »   lab-essai          tâche de build par défaut (Ctrl+Maj+B)
//   « Lab : état de l'essai »      lab-essai status
//   « Lab : arrêter l'essai »      lab-essai stop
//
// Chaque tâche lance la commande `lab-essai` de l'image, directement (ProcessExecution :
// pas de shell, aucun argument tiré du projet), avec l'environnement de l'espace. Aucun
// jeton n'est lu ici.
'use strict';
const vscode = require('vscode');

const TYPE = 'lab-essai';
// VS Code affiche une tâche fournie par une extension sous la forme « <source>: <nom> ».
// La source « Lab » suivie d'une espace donne exactement « Lab : <nom> ».
const SOURCE = 'Lab ';
const TACHES = [
  { action: 'construire', nom: "construire l'essai", args: [], detail: "Construit l'essai à partir du dossier de travail (non commité compris) et affiche son adresse", defaut: true },
  { action: 'etat', nom: "état de l'essai", args: ['status'], detail: "Ce que montre l'adresse d'essai, et jusqu'à quand" },
  { action: 'arreter', nom: "arrêter l'essai", args: ['stop'], detail: "Arrête l'essai ; sa base est conservée" },
];

// Groupe « build » marqué par défaut. Une instance à part : TaskGroup.Build est partagé par
// toutes les extensions de l'hôte, le marquer rendrait « par défaut » les tâches des autres.
function groupeBuildParDefaut() {
  try {
    const g = new vscode.TaskGroup('build', 'Build');
    g.isDefault = true;
    return g;
  } catch (_e) {
    return vscode.TaskGroup.Build;
  }
}

function tache(t, definition) {
  const dossier = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0];
  const task = new vscode.Task(
    definition || { type: TYPE, action: t.action },
    dossier || vscode.TaskScope.Workspace,
    t.nom,
    SOURCE,
    new vscode.ProcessExecution('lab-essai', t.args),
    []);   // tableau vide et non « rien » : l'éditeur ne propose pas d'associer un détecteur d'erreurs (il l'écrirait dans le dépôt)
  task.detail = t.detail;
  task.presentationOptions = {
    reveal: vscode.TaskRevealKind.Always, focus: false, clear: true,
    panel: vscode.TaskPanelKind.Dedicated, showReuseMessage: false,
  };
  if (t.defaut) task.group = groupeBuildParDefaut();
  return task;
}

function activate(context) {
  context.subscriptions.push(vscode.tasks.registerTaskProvider(TYPE, {
    provideTasks: () => TACHES.map(t => tache(t)),
    resolveTask: task => {
      const t = TACHES.find(x => x.action === (task.definition && task.definition.action));
      return t ? tache(t, task.definition) : undefined;
    },
  }));
}

function deactivate() {}

module.exports = { activate, deactivate };
