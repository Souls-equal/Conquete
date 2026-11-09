# Conquête — activer le multijoueur Supabase (prototype)

Cette version ajoute des salles en ligne à l’interface existante, sans enlever le mode local ni les bots. Le navigateur du créateur de salle exécute les règles et fait office d’arbitre ; Supabase Auth et Realtime identifient les membres et transportent les messages. Chaque invité ne reçoit que sa propre vue filtrée de la carte.

## Configuration Supabase

1. Crée un projet Supabase (ou utilise celui que tu as déjà).
2. Dans **SQL Editor**, colle et exécute tout le contenu de [`supabase/setup.sql`](supabase/setup.sql).
3. Dans **Authentication → Sign In / Providers**, active les connexions anonymes (**Anonymous sign-ins**).
4. Dans **Project Settings → API**, relève l’URL du projet et la clé publique **anon** ou **publishable**. Ne mets jamais une clé `service_role` dans la page.
5. Ouvre Conquête depuis son site HTTPS (ou depuis `localhost` en développement), clique **Jouer en ligne**, saisis l’URL et la clé publique, puis crée une salle. Les autres joueurs saisissent le même projet et le code de salle.

Il n’y a pas de table de partie à créer : le SQL installe les fonctions de salle et les politiques RLS qui protègent les canaux Realtime privés. Si ton projet possède déjà des politiques sur `realtime.messages`, vérifie qu’aucune politique plus permissive ne donne un accès général : les politiques permissives PostgreSQL se combinent.

## Limites de cette première version

- L’hôte et les invités doivent garder leur navigateur ouvert et connecté. Si un invité se déconnecte pendant son tour, il doit rejoindre de nouveau avec le même navigateur ; sinon la partie attendra son action. Utilise **Quitter la salle** pour libérer proprement une place dans le lobby.
- L’hôte est aussi l’arbitre et son navigateur possède l’état complet de la carte. Les autres joueurs ne reçoivent que leur vue filtrée, mais cette version n’est pas conçue pour une partie compétitive contre un hôte malhonnête.
- Les parties ne sont pas sauvegardées après fermeture ou redémarrage de l’hôte.
- Pour une version compétitive et persistante, il faudra déplacer le moteur de jeu dans une Edge Function Supabase et enregistrer l’état de la partie côté serveur.

La clé saisie dans le jeu est publique et reste dans le stockage local de ce navigateur. Les politiques SQL n’autorisent pas l’accès direct aux tables de salle ; les fonctions RPC et les canaux Realtime privés sont contrôlés par RLS.
