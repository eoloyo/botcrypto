# Grume Lab

App iPhone pour tester des grumes avant de les scier :

- **Résonance** : on frappe le bout de la grume et l'app écoute. Elle donne la fréquence, la vitesse du son le long des fibres, la rigidité dynamique et l'amortissement (combien de temps le son dure).
- **LiDAR** : mesure de la longueur et des diamètres en visant la grume avec la caméra (iPhone Pro avec LiDAR).
- **Grumes** : un carnet qui garde les dimensions et les mesures de chaque grume.

Les résultats sont des indications pour trier les grumes. Ils ne remplacent pas un classement de structure officiel.

## Installer l'app sur l'iPhone depuis un PC Windows

L'app est compilée automatiquement par GitHub à chaque modification. Le fichier à installer s'appelle `GrumeLab.ipa`.

### Une seule fois

1. Sur le PC, installez **Sideloadly** depuis son site officiel (sideloadly.io). S'il le demande, installez aussi **iTunes** depuis le site d'Apple (pas la version du Microsoft Store).
2. Sur l'iPhone, activez le **Mode développeur** : Réglages › Confidentialité et sécurité › Mode développeur. L'iPhone redémarre.

### Installer ou mettre à jour

1. Téléchargez le dernier `GrumeLab.ipa` dans les **Releases** de ce dépôt (colonne de droite sur la page GitHub), celles nommées « Grume Lab, build … ».
2. Branchez l'iPhone au PC en USB et touchez « Faire confiance » sur l'iPhone si on vous le demande.
3. Ouvrez Sideloadly, glissez `GrumeLab.ipa` dans la fenêtre, entrez votre identifiant Apple et cliquez sur **Start**.
4. Sur l'iPhone : Réglages › Général › VPN et gestion de l'appareil, touchez votre identifiant Apple, puis **Faire confiance**.
5. Ouvrez Grume Lab.

Avec un identifiant Apple gratuit, l'app expire au bout de **7 jours** : refaites simplement l'étape 3. Sideloadly peut le faire tout seul si le PC reste allumé sur le même Wi-Fi que l'iPhone.

## Utilisation

### Résonance
1. Posez la grume sur deux cales, sans contact avec le sol.
2. Choisissez la grume et vérifiez sa longueur.
3. Tenez le téléphone près d'un bout, touchez **Écouter**, puis donnez un coup de marteau sec sur l'autre bout, dans l'axe.
4. Faites 3 mesures : elles doivent donner presque la même fréquence. Enregistrez-les.

Calculs : vitesse = 2 × longueur × fréquence ; rigidité dynamique = densité × vitesse². Sans masse saisie, l'app suppose 850 kg/m³ (bois vert).

### LiDAR
- **Longueur** : visez le centre d'un bout, touchez « Point », marchez jusqu'à l'autre bout en gardant la grume dans l'image, visez son centre, touchez « Point ».
- **Diamètre** : visez le bord de la coupe sous l'écorce, puis le bord opposé en passant par le cœur.
- Précision attendue : de l'ordre du centimètre de près. Comparez au mètre ruban les premières fois.

## Développement

Le projet Xcode est généré par [XcodeGen](https://github.com/yonaskolb/XcodeGen) à partir de `project.yml`. La compilation se fait sur les machines macOS de GitHub Actions (`.github/workflows/grume-lab-ios.yml` à la racine du dépôt), sans signature : Sideloadly signe l'app avec votre identifiant Apple au moment de l'installation.

Sur un Mac, depuis ce dossier : `brew install xcodegen && xcodegen generate && open GrumeLab.xcodeproj`.
