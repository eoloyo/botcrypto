# Grume Lab

App iPhone pour tester des grumes avant de les scier :

- **Résonance** : on frappe le bout de la grume et l'app écoute. Elle donne la fréquence, la vitesse du son le long des fibres, la rigidité dynamique et l'amortissement (combien de temps le son dure).
- **LiDAR** : mesure de la longueur et des diamètres en visant la grume avec la caméra (iPhone Pro avec LiDAR).
- **Scan 3D** : forme réelle de la grume (diamètre, conicité, courbure tous les 10 cm), en tournant autour avec le LiDAR.
- **Débit** : plan de coupe qui cherche le meilleur rendement (poutres et planches, trait de scie, tronçonnage éventuel), avec une coupe dessinée et une vue 3D.
- **Cœur et cernes** : à partir d'une photo de chaque bout, position du cœur, nombre et largeur des cernes, bois juvénile, duramen, et comparaison des deux bouts. Le cœur est reporté sur le plan de coupe.
- **Couleurs réelles en 3D** : pendant le scan, la caméra colore la surface de la grume.
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

### Scan 3D (onglet LiDAR, mode « Scan 3D »)
1. Visez le cœur du premier bout et touchez « Point », puis le cœur de l'autre bout.
2. Tournez lentement autour de la grume à environ 1 m, en filmant le dessus et les côtés sur toute la longueur. Le compteur de points monte.
3. Touchez « Calculer la forme », vérifiez les dimensions, puis « Enregistrer la forme dans la grume ».

Le dessous de la grume (contre le sol ou les cales) n'est pas utilisé : la forme est reconstruite à partir du dessus et des côtés.

### Cœur et cernes (fiche de la grume)
1. Recoupez une fine tranche, mouillez la surface, photographiez bien de face, téléphone droit.
2. Placez le cercle bleu sur le bord du bois (sous l'écorce) et vérifiez le point rouge sur le cœur (trouvé automatiquement).
3. Indiquez le diamètre de la coupe, puis « Analyser les cernes ».

L'app donne le nombre de cernes (± 5 % environ), leur largeur près du cœur, au milieu et sous l'écorce, le décalage du cœur, la zone de bois juvénile (12 premiers cernes) et, si le contraste de couleur le permet, le diamètre du duramen. Avec les deux bouts, elle compare les cernes et suit le cœur sur la longueur.

### Débit
L'app prend la forme scannée, ou à défaut une forme estimée à partir de la longueur, des diamètres et de la courbure. La partie sciable sur toute la longueur est l'intersection de toutes les coupes : la conicité et la courbure la réduisent. L'app y place une ou deux poutres (sections réglables) et des planches autour, ou seulement des planches, en tenant compte du trait de scie, et teste un tronçonnage en deux si la grume est courbe.

Le rendement affiché est le volume des pièces sur le volume de la grume. Le plan ne voit pas l'intérieur du bois (nœuds, pourriture, cœur) : vérifiez les bouts avant de scier.

## Développement

Le projet Xcode est généré par [XcodeGen](https://github.com/yonaskolb/XcodeGen) à partir de `project.yml`. La compilation se fait sur les machines macOS de GitHub Actions (`.github/workflows/grume-lab-ios.yml` à la racine du dépôt), sans signature : Sideloadly signe l'app avec votre identifiant Apple au moment de l'installation.

Sur un Mac, depuis ce dossier : `brew install xcodegen && xcodegen generate && open GrumeLab.xcodeproj`.
