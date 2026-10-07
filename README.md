# CoursLocal — application personnelle macOS

CoursLocal enregistre un cours, le transcrit avec **Whisper intégré via WhisperKit**, puis utilise un modèle de langage — **local avec Rapid MLX Desktop** ou **cloud avec OpenRouter** — pour **nettoyer** le texte (tics de langage, hésitations, erreurs de transcription) et le **découper en paragraphes et en thèmes**. Le résultat est une note **Markdown compatible Obsidian**.

Cible : **Apple Silicon, macOS 14 ou ultérieur**. Développement et tests automatisés réalisés sur un **M5 Pro avec 24 Go de mémoire**. Version 0.3.0, à lancer localement depuis Xcode.

## Démarrage

1. Ouvre `CoursLocal.xcodeproj` dans Xcode, laisse résoudre WhisperKit (Argmax OSS 1.1.0), choisis le schéma **CoursLocal** et la destination **My Mac**, puis lance avec **⌘R**. La signature ad hoc ne demande pas d’abonnement développeur.
2. Dans **Rapid MLX Desktop**, démarre le serveur API et expose un **modèle de texte local** déjà installé. CoursLocal ne télécharge ni ne choisit de modèle texte automatiquement. Ollama n’est plus utilisé.
3. Dans **CoursLocal → Réglages… → IA** (**⌘,**), choisis **Local · Rapid MLX** et renseigne l’adresse du serveur : `http://127.0.0.1:7659/v1` par défaut. Le port doit correspondre à celui affiché dans Rapid MLX Desktop.
4. Renseigne la clé API uniquement si ton serveur en exige une. Clique sur **Tester et actualiser les modèles**, puis choisis le modèle texte (`deepseek-coder-v2-lite-16b-4bit` dans ta configuration Rapid MLX). Copie la clé complète depuis Rapid MLX ; la valeur abrégée affichée à l’écran ne suffit pas. La clé est conservée dans le trousseau macOS, pas dans les fichiers des cours.
5. Choisis la langue et le modèle Whisper : large-v3 Turbo (précis), medium (équilibré) ou small (rapide). Le premier traitement peut télécharger Whisper et préparer son tokenizer. Après préparation, la transcription est locale.
6. Facultatif : dans **Réglages → Obsidian**, choisis ton coffre (et un sous-dossier, `Cours` par défaut) pour exporter en un clic.
7. Clique sur **Enregistrer**, saisis un titre et choisis la source audio. Termine le cours pour démarrer automatiquement son traitement, ou désactive ce comportement dans les réglages.

Dans Rapid MLX, utilise un modèle local sans routage cloud. En mode local, CoursLocal contacte exclusivement les adresses de boucle locale, ignore les proxies et refuse les redirections HTTP ; il n’a aucun repli vers une API externe.

### Mode cloud (OpenRouter)

Dans **Réglages → IA**, choisis **Cloud · OpenRouter**, colle ta clé (créée sur openrouter.ai), clique sur **Vérifier la clé**, puis **Parcourir…** pour choisir un modèle (recherche, filtre « gratuits », tri par prix, coût estimé pour 2 h de cours). Seul `https://openrouter.ai/api/v1` est contacté ; les redirections sont refusées.

- **Le texte des transcriptions quitte le Mac** et est traité par OpenRouter et le fournisseur du modèle. L’audio, Whisper et l’export restent locaux.
- Les requêtes imposent un **schéma JSON strict** (sorties structurées) et un raisonnement à effort faible, non renvoyé : les modèles à raisonnement (GPT-6, etc.) comptent leur réflexion dans `max_tokens`, dont le plafond est donc large (16 000 tokens, facturés à l’usage).
- L’option **Exclure les fournisseurs qui conservent ou réutilisent les données** (activée par défaut) envoie `provider.data_collection = "deny"`.
- Erreurs explicites : clé refusée, crédit insuffisant (402), modèle introuvable. Changer de fournisseur ou de modèle demande une régénération du document.

### Clés API et trousseau

Les clés (Rapid MLX et OpenRouter) sont stockées dans le trousseau macOS, jamais dans les fichiers des cours. L’écran des réglages et la vérification automatique **ne lisent jamais la clé** : ils regardent seulement si elle existe, ce qui ne déclenche pas de demande de mot de passe. La clé n’est lue qu’au moment de l’utiliser (traitement, **Tester**, **Vérifier la clé**, ↻), puis gardée en mémoire jusqu’à la fermeture de l’app. Comme l’app est signée ad hoc, macOS peut redemander l’accès après chaque recompilation : choisis **Toujours autoriser**.

## Enregistrement et import

Trois modes sont proposés :

- **Microphone** : périphérique d’entrée par défaut des Réglages Système → Son.
- **Application** : son de l’application ouverte choisie, par exemple Zoom, Teams ou un navigateur.
- **Micro + application** : mélange des deux sources, alignées sur l’horloge hôte, avec réduction de gain. Utilise un casque pour éviter que le microphone reprenne les haut-parleurs ; cette version ne fournit pas d’annulation d’écho acoustique.

Le mode microphone demande l’autorisation microphone. La capture d’application utilise ScreenCaptureKit et demande l’autorisation macOS d’enregistrement de l’écran et du son système. **Aucune vidéo ni image n’est sauvegardée.** Le son de CoursLocal est exclu et son lecteur est désactivé pendant toute capture.

La capture reste ouverte lors des rotations : un service séparé écrit des **WAV mono, 16 kHz, 16 bits**, finalisés exactement toutes les cinq minutes audio. Deux heures représentent environ **230 Mo**, hors modèles. Les pauses sont retirées de la durée audio et des horodatages.

Les files audio sont bornées. Une surcharge, une erreur disque, un changement de microphone, la fermeture de l’application capturée ou la veille interrompent explicitement l’enregistrement en conservant les fichiers disponibles. La prévention de la veille automatique ne garantit pas la continuité lors de la fermeture du capot ou d’une extinction.

**Enregistrement rapide** : le raccourci global **⌥⌘R** (modifiable dans Réglages → Général) démarre un enregistrement sans titre, même quand CoursLocal est en arrière-plan, puis le termine au second appui. La source audio du raccourci se règle au même endroit ; en mode application, c’est l’application au premier plan qui est capturée. Pendant tout enregistrement, une pastille flottante en bas de l’écran indique que la capture est active et affiche la durée enregistrée : le point met en pause ou reprend, ✕ termine. Le raccourci passe par Carbon `RegisterEventHotKey` et ne demande pas l’autorisation d’accessibilité.

Le bouton **Importer** accepte les formats reconnus par AVFoundation et les convertit en segments M4A de cinq minutes. L’import est annulable. Un import incomplet reste signalé et ne peut pas être traité ; **Réimporter le fichier original** crée un nouvel import complet sans effacer le précédent.

## App iPhone : enregistrer, puis envoyer au Mac

L’app **CoursLocal** pour iPhone (cible `CoursLocalMobile`, iOS 17 ou ultérieur) ne fait qu’une chose : enregistrer le cours avec le micro de l’iPhone, puis envoyer l’audio au Mac, qui fait la transcription, le nettoyage et la fiche comme pour un enregistrement fait sur le Mac.

### Installation sur l’iPhone

1. Branche l’iPhone au Mac, ouvre `CoursLocal.xcodeproj` et choisis le schéma **CoursLocalMobile** puis ton iPhone comme destination.
2. Dans la cible **CoursLocalMobile → Signing & Capabilities**, choisis ton équipe : un **identifiant Apple gratuit** (Personal Team) suffit. Si l’identifiant `fr.baptiste.CoursLocal.mobile` est refusé, remplace-le par un autre identifiant unique.
3. Lance avec **⌘R**. Au premier lancement, active le **mode développeur** sur l’iPhone (Réglages → Confidentialité et sécurité) et fais confiance au profil (Réglages → Général → VPN et gestion de l’appareil). Avec un compte gratuit, l’app doit être réinstallée depuis Xcode tous les 7 jours ; les enregistrements sont conservés.

### Appairage

Dans **CoursLocal → Réglages… → iPhone** sur le Mac, laisse **Recevoir les enregistrements de l’iPhone** activé et note le **code d’appairage** à 6 chiffres. Dans l’app iPhone, touche ⚙︎ et saisis ce code, une seule fois. Accepte les demandes d’accès au **réseau local** sur les deux appareils (et les connexions entrantes si le pare-feu macOS le demande). **Générer un nouveau code** sur le Mac révoque l’ancien : l’iPhone redemandera le code.

### Utilisation

- Saisis un titre si tu veux (sinon « Cours du … ») et touche le bouton rouge. Tu peux **verrouiller l’écran** : l’enregistrement continue en arrière-plan. **Pause** n’enregistre plus rien et le temps de pause est retiré ; le micro reste ouvert pour que la reprise fonctionne aussi depuis le Mac, écran verrouillé. Un appel met l’enregistrement en pause et il reprend tout seul ensuite. Le micro intégré est toujours utilisé, même avec des AirPods connectés.
- **Terminer** (avec confirmation) clôt l’enregistrement. Dès que le Mac est visible, app ouverte des deux côtés, l’envoi part automatiquement (désactivable). L’iPhone et le Mac se trouvent sur le même Wi-Fi ou **directement à proximité, en pair-à-pair comme AirDrop**, ce qui marche aussi quand le Wi-Fi de l’établissement isole les appareils.
- Sur le Mac, un bandeau montre la réception. Chaque enregistrement reçu devient un cours daté du moment de l’enregistrement, puis est traité automatiquement si **Traiter automatiquement** est activé. Si le Mac est occupé (enregistrement, traitement…), l’enregistrement reçu attend sur le disque et devient un cours dès que le Mac est libre.
- Sur l’iPhone, chaque enregistrement est marqué **À envoyer** ou **Sur le Mac** ; appui long pour envoyer à nouveau, renommer ou supprimer. L’option **Supprimer de l’iPhone après l’envoi** libère la place automatiquement.

### Contrôle depuis le Mac

Dès que l’app iPhone est appairée et ouverte, elle garde une connexion de contrôle avec le Mac (même code d’appairage) :

- Sur le Mac, une carte en bas de la barre latérale montre l’iPhone connecté et son état (prêt, nombre d’enregistrements à envoyer, envoi en cours). Le bouton ● de la carte, ou **Enregistrer sur l’iPhone** dans la barre d’outils, demande un titre facultatif puis démarre l’enregistrement sur l’iPhone.
- Pendant un enregistrement iPhone, un bandeau rouge affiche en temps réel la durée, le niveau du micro et les messages de l’iPhone (interruption par un appel…), avec **Pause**, **Reprendre** et **Terminer** (confirmation). À la fin, l’iPhone envoie l’audio au Mac, qui le traite comme d’habitude.
- L’iPhone envoie son état environ cinq fois par seconde pendant un enregistrement, sinon toutes les deux secondes ; le Mac le relance toutes les trois secondes. Si la connexion est perdue pendant un enregistrement (iPhone hors de portée), le bandeau le signale et garde la dernière durée connue : **l’enregistrement continue sur l’iPhone**, et le contrôle revient dès que l’iPhone se reconnecte.
- Une commande impossible sur l’iPhone (micro refusé…) s’affiche en alerte sur le Mac.

**Limite d’iOS** : une app en arrière-plan ne peut pas ouvrir le micro, et une app inactive est suspendue. Le Mac peut donc toujours contrôler un enregistrement en cours, même écran verrouillé, mais pour **démarrer** un enregistrement l’app iPhone doit être ouverte, sauf si l’option **Rester joignable en arrière-plan** est activée (Réglages de l’app iPhone). Avec cette option, le micro reste ouvert sans rien enregistrer (point orange visible, un peu de batterie) pour que l’app reste active et joignable. L’option doit être activée app ouverte.

### Fiabilité

- L’audio est écrit en **WAV mono 16 kHz 16 bits, un fichier par tranche de cinq minutes**, exactement comme sur le Mac (environ 115 Mo par heure). Si l’app est tuée ou la batterie se vide, l’enregistrement est récupéré au lancement suivant : l’en-tête du dernier segment est réparé et rien de ce qui a été écrit n’est perdu.
- Le Mac ne confirme l’envoi qu’après avoir **écrit, synchronisé et relu** chaque segment avec AVFoundation ; un segment illisible fait refuser l’envoi, qui reste à faire sur l’iPhone. Un enregistrement renvoyé après une confirmation perdue est reconnu et n’est pas importé deux fois.
- Le Mac n’accepte qu’un iPhone à la fois, refuse les codes incorrects (avec délai, puis une minute de blocage après cinq erreurs), limite la taille et le nombre de segments et n’écrit que des noms de fichiers qu’il choisit. Le transfert reste sur le réseau local, sans chiffrement propre : n’utilise pas l’appairage sur un réseau auquel tu ne fais pas confiance.
- Les fichiers WAV sont aussi visibles dans l’app **Fichiers** et dans le **Finder** (iPhone branché), en dernier recours.

## Questions sur un cours

Le bouton bulle, à droite des onglets d’un cours, ouvre le panneau **Questions** dès que le texte est transcrit. L’IA configurée (Rapid MLX ou OpenRouter) répond d’abord à partir du cours et cite les moments `[hh:mm:ss]`, cliquables pour réécouter le passage. Si le cours ne suffit pas, elle le dit et peut compléter dans un paragraphe « Hors cours : ».

Le texte nettoyé est envoyé s’il existe, sinon la transcription. En cloud, un cours de deux heures part en entier ; en local (environ 12 000 caractères), seules les sections qui partagent le plus de mots avec la question et la précédente sont envoyées, dans l’ordre du cours. La conversation est conservée avec le cours mais n’est jamais exportée vers Obsidian. Une question continue si l’on change de cours.

## Nettoyage, paragraphes et thèmes

1. **Transcription** : Whisper transcrit les segments dans l’ordre, puis est libéré avant le nettoyage.
2. **Filtrage déterministe** : avant tout appel au modèle, les hésitations évidentes (« euh », « hum », « bah », « hein »…), les bégaiements (« de de », « c’est c’est »), les annotations Whisper (`[Musique]`, `(rires)`) et les phrases inventées sur les silences (« Sous-titrage… », « Merci d’avoir regardé… ») sont retirés. Les répétitions légitimes (« nous nous », « très très ») sont conservées.
3. **Nettoyage par le modèle** : la transcription est découpée en blocs d’environ 3 000 caractères, **sans chevauchement**, en lignes numérotées. Pour chaque bloc, le modèle retire les tics dépendants du contexte (« du coup », « en fait », « voilà »…), corrige les erreurs de transcription certaines, puis regroupe le texte en paragraphes et en sections titrées, chacune rattachée à un thème. Les thèmes déjà trouvés et la section précédente lui sont rappelés pour garder des noms cohérents.
4. **Contrôles** : une réponse qui perd du contenu (moins de 45 % du texte source), en invente (plus de 160 %) ou ne référence pas la moitié des lignes est refusée ; une seule nouvelle tentative est faite. Les corrections annoncées dont le mot d’origine n’existe pas dans la source sont ignorées. Une réponse tronquée (limite de tokens atteinte) est redemandée avec un budget doublé. Si le modèle échoue deux fois, le passage est conservé avec le seul filtrage déterministe et marqué **« Nettoyage simplifié »**, avec la cause affichée, au lieu de bloquer le cours ; **Réessayer** renvoie uniquement ces passages au modèle. Les erreurs de connexion, elles, arrêtent le traitement.
5. **Harmonisation des thèmes** : une dernière requête, qui ne contient que les noms de thèmes, fusionne les synonymes (2 à 8 thèmes) et propose des mots-clés. En cas de réponse invalide, les thèmes détectés sont gardés tels quels.

6. **Fiche de cours** (désactivable dans Réglages → Général) : à partir du **texte nettoyé**, une requête par thème produit une synthèse rédigée, 3 à 8 points clés, les définitions, les exemples cités et ce que le professeur signale comme important (examen, « à savoir »). Un thème trop long est traité en plusieurs parties, sans couper une section, puis fusionné. Une dernière requête rédige **l’essentiel** du cours, 5 à 10 points **à retenir** et 4 à 8 **questions de révision** avec réponse. Les consignes interdisent d’ajouter des connaissances extérieures et demandent d’ignorer les passages incompréhensibles plutôt que de deviner.

Chaque étape est sauvegardée atomiquement : une relance réutilise la transcription, les blocs déjà nettoyés et les fiches de thèmes déjà rédigées. **Régénérer la fiche** la recrée à partir du texte nettoyé actuel, corrections manuelles comprises, sans refaire le reste. Les erreurs HTTP temporaires sont réessayées au maximum deux fois, en respectant `Retry-After`.

Un seul enregistrement, import, traitement ou changement de données peut être actif à la fois. Une capture interrompue exige d’abord une vérification manuelle. Si un segment est illisible, **Traiter les portions valides** demande d’accepter explicitement un cours incomplet.

## Interface

- **Bibliothèque** groupée par date (aujourd’hui, hier, 7 derniers jours…), avec état, durée et thèmes de chaque cours, recherche dans les titres, transcriptions, documents et thèmes, et un indicateur de l’IA locale. La vérification automatique ne lit pas le trousseau ; ↻ refait la vérification avec la clé API.
- **Bandeaux** d’enregistrement (niveaux micro/application, pause, fin) et de traitement (étapes Vérification → Transcription → Nettoyage → Thèmes, interruption).
- **Fiche** (onglet par défaut) : l’essentiel, à retenir, fiche par thème (synthèse, points clés, définitions, exemples, remarques du professeur, accès à l’audio) et questions de révision à réponse masquée.
- **Texte nettoyé** : lecture par thème ou dans l’ordre chronologique, plan cliquable à droite, horodatage de chaque section pour réécouter le passage, mise en évidence de la section en cours de lecture, liste des corrections de transcription. Chaque section se modifie (titre, thème, paragraphes) et chaque thème se renomme (donner le nom d’un autre thème fusionne les deux).
- **Transcription** brute horodatée, filtrable, avec correction par passage. Une correction marque le document **obsolète** ; **Régénérer** demande confirmation avant de remplacer le document et ses modifications.
- **Markdown** : aperçu exact du fichier exporté.
- **Archives** : notes, fiches et résumés produits par la version 0.2, conservés en lecture seule.
- **Lecteur** en bas de fenêtre : ±15 s, déplacement, vitesses 0,75× à 2×.

## Export Obsidian

**Exporter vers Obsidian** écrit `Titre du cours.md` dans le coffre choisi (après confirmation si la note existe déjà, pour ne pas écraser des modifications faites dans Obsidian), puis ouvre la note via `obsidian://`. Sans coffre configuré, l’export demande où enregistrer. **Copier le Markdown** place la note dans le presse-papiers.

La note contient :

- la **fiche de cours** en tête : encadré `[!abstract] L’essentiel`, `## À retenir`, une section `##` par thème (synthèse, **Points clés**, **Définitions**, **Exemples**, encadré `[!important] Signalé par le professeur`) et `## Questions de révision` en encadrés `[!question]-` repliables ;
- puis `## Texte nettoyé` (thèmes en `###`, sections en `####`), facultatif ;
- des **propriétés YAML** : `title`, `date`, `duration`, `source`, `language`, `tags` (`cours` + mots-clés + thèmes), `themes`, et `status` si le cours est incomplet ou obsolète ;
- un **sommaire** de liens `[[#Thème]]` lorsqu’il y a plusieurs thèmes ;
- les thèmes en `##`, les sections en `###` avec leur plage horaire (ou, en mode chronologique, les sections en `##` suivies de leur `#tag` de thème) ;
- des **encadrés** Obsidian : avertissements (`[!warning]`), passages simplifiés (`[!caution]`), corrections de transcription en tableau (`[!info]-`, repliable), anciens résultats (`[!note]-`) et transcription brute (`[!quote]-`, facultative).

## Stockage et migration

Audio et métadonnées se trouvent dans le dossier Application Support du conteneur sandbox de CoursLocal. **Fichiers audio** ouvre le dossier du cours.

- Un fichier `course.json` versionné par cours, avec écritures atomiques sérialisées hors du thread principal.
- Un `recording-manifest.json` écrit avant la création des segments, permettant leur récupération après un crash. Le dernier WAV peut rester endommagé ; les segments précédents sont indépendants.
- La migration des anciens cours sauvegarde d’abord les octets originaux dans `course.vN.backup.json` (N = ancien format). Audio, transcription, notes, résumé et fiches sont conservés ; les cours au format 2 peuvent être nettoyés directement, sans perdre leurs anciens résultats.
- Le coffre Obsidian est mémorisé par un signet de sécurité (`com.apple.security.files.bookmarks.app-scope`).
- Les métadonnées illisibles ou incompatibles sont signalées et conservées, jamais supprimées automatiquement.
- Les erreurs, la configuration du traitement, la version des prompts et la révision de la transcription sont persistées. Les secrets du serveur ne le sont pas.

## Vérification

Depuis la racine du projet :

```sh
xcodebuild -project CoursLocal.xcodeproj -scheme CoursLocal -destination 'platform=macOS' test
xcodebuild -project CoursLocal.xcodeproj -scheme CoursLocal -destination 'platform=macOS' -configuration Release build
```

Pour vérifier que l’app iPhone compile sans signer :

```sh
xcodebuild -project CoursLocal.xcodeproj -scheme CoursLocalMobile -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

La configuration fixe l’architecture à arm64. Les tests utilisent des bibliothèques temporaires et des transcriptions simulées ; ils ne téléchargent aucun modèle et ne capturent pas le microphone réel.

Pour inclure le test du transport HTTP réel avec URLSession, démarre dans un autre terminal le serveur **de test uniquement** :

```sh
python3 CoursLocalTests/Fixtures/rapid_mlx_mock.py
```

Il écoute sur `127.0.0.1:38991`, ne fait aucune inférence et ne transmet aucune donnée à Internet. Arrête-le avec **Ctrl+C** après les tests. En son absence, ce seul test est ignoré.

La suite couvre notamment :

- découpage Unicode, conservation des sources, horodatages et sérialisation ;
- API Chat Completions, modèles exposés, erreurs, réessais et annulation ;
- filtre des tics, bégaiements, annotations et hallucinations Whisper ; réparation et refus des réponses de nettoyage ; harmonisation des thèmes ; repli sans perte quand le modèle échoue ;
- fusion des sections entre blocs, regroupement par thème, édition de section et renommage de thème ;
- Markdown Obsidian : propriétés YAML, tags, liens, encadrés, noms de fichiers ;
- OpenRouter : adresse fixe, en-têtes, préférence de confidentialité, clé manquante ou refusée, crédit insuffisant, catalogue tolérant aux entrées invalides ;
- blocage des adresses externes et des redirections, y compris avec transport HTTP réel ;
- refus simulé des permissions microphone et son système ;
- continuité exacte aux rotations et signalement de la surcharge d’écriture ;
- **deux heures de signal synthétique**, écrites en 24 segments puis relues : comparaison des 115,2 millions d’échantillons ;
- mixage des sources et exclusion du temps passé en pause ;
- migration avec sauvegarde, récupération du manifeste, conservation des fichiers illisibles ;
- correction sans perte des éditions et reprise après échec de l’harmonisation des thèmes ;
- rendu de l’interface avec un cours de démonstration ;
- transfert iPhone → Mac réel en boucle locale : création du cours, durées relues, renvoi sans doublon, code incorrect, audio illisible refusé sans rien garder, attente quand le Mac est occupé, réparation d’un WAV interrompu ;
- canal de contrôle : état en direct, relais des commandes, erreur de l’iPhone signalée une seule fois, envoi d’un enregistrement pendant le contrôle, perte de connexion pendant un enregistrement, code d’appairage exigé.

### Validation réelle restant à effectuer

Ces tests automatisés ne remplacent pas les essais suivants :

1. Sur le Mac cible, enregistrer et écouter une courte session dans chacun des trois modes ; vérifier les permissions, la pause et les changements de périphérique.
2. Avec un modèle réellement exposé par Rapid MLX Desktop, transcrire un cours français représentatif et vérifier que le nettoyage conserve chiffres, termes techniques et exemples, que les corrections sont justes et que les thèmes sont pertinents. Un modèle d’instruction généraliste convient mieux qu’un modèle de code.
3. Réaliser une capture réelle de deux heures ; contrôler les frontières audio, la dérive entre sources, la mémoire et le temps de traitement.
4. Interrompre puis relancer le parcours, vérifier le lecteur, les corrections et l’export après redémarrage ; ouvrir la note exportée dans Obsidian (propriétés, sommaire, encadrés).
5. Après téléchargement des modèles, répéter le parcours hors ligne.
6. Sur un iPhone réel : enregistrer écran verrouillé pendant au moins 15 minutes, recevoir un appel pendant l’enregistrement, débrancher/brancher un casque, forcer la fermeture de l’app pendant un enregistrement puis la rouvrir ; envoyer au Mac en Wi-Fi puis Wi-Fi coupé (pair-à-pair). Depuis le Mac : démarrer avec l’app iPhone ouverte, puis iPhone verrouillé avec « Rester joignable » ; mettre en pause, reprendre et terminer écran verrouillé ; éloigner l’iPhone pendant un enregistrement puis le rapprocher.

## Structure

- `AudioRecorder.swift` : AVAudioEngine, ScreenCaptureKit, mixage et écriture segmentée.
- `LocalAI.swift` : WhisperKit, fournisseurs (Rapid MLX, OpenRouter), client Chat Completions (nettoyage, harmonisation des thèmes), validation de l’adresse et trousseau.
- `Pipeline.swift` : orchestration, import, nettoyage par blocs avec reprise.
- `CleanDocument.swift` : document nettoyé (sections, paragraphes, thèmes), filtre déterministe, validation des réponses du modèle.
- `ObsidianExport.swift` : génération du Markdown Obsidian et export vers le coffre.
- `CourseStore.swift` : bibliothèque observable, dépôt de fichiers sérialisé, éditions du document.
- `Models.swift` : cours versionnés, sources, anciens résultats, états et découpage.
- `PhoneReceiver.swift` : réception des enregistrements de l’iPhone (Bonjour, boîte de réception durable, création des cours).
- `Shared/PhoneTransfer.swift` : protocole de transfert iPhone → Mac et réparation des WAV interrompus, compilé dans les deux apps.
- `PhoneRemoteViews.swift` : bandeau d’enregistrement iPhone en direct, carte de l’iPhone connecté, démarrage à distance.
- `CoursLocalMobile/` : app iPhone (enregistreur segmenté avec veille joignable, bibliothèque locale, recherche du Mac et envoi, connexion de contrôle `MacRemote.swift`, interface).
- `RecordingShortcut.swift` : raccourci global, pastille flottante d’enregistrement et capture du raccourci dans les réglages.
- `CourseChat.swift` : panneau Questions, choix des extraits envoyés et invite « cours d’abord ».
- `ContentView.swift` : fenêtre principale, bibliothèque, bandeaux, accueil, nouveau cours.
- `CourseDetailView.swift` : détail d’un cours (document, transcription, Markdown, archives, plan).
- `Components.swift` : lecteur audio et composants partagés.
- `SettingsView.swift` : réglages (transcription, IA locale ou OpenRouter avec catalogue des modèles, Obsidian, général).
- `CoursLocalTests/` : tests et serveur HTTP de test facultatif.

Références : [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift), [API Rapid MLX](https://rapidmlx.com/docs/api), [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit).
