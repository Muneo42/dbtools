# Projet DBTools — Infrastructure as Code

Environnement d'évaluation de **DbToolsBundle** (sauvegarde / restauration / anonymisation de bases de données), reconstruit intégralement en IaC avec **OpenTofu** (provisioning) et **Ansible** (configuration).

L'ensemble se détruit et se reconstruit d'une seule commande : du conteneur vide jusqu'au premier backup fonctionnel, sans aucune intervention manuelle.

---

## Architecture

| ID  | Hôte         | IP            | Type | Rôle                          |
|-----|--------------|---------------|------|-------------------------------|
| 160 | `dbtools`    | 192.168.1.160 | LXC  | Client DbToolsBundle (PHP)    |
| 161 | `mariadb`    | 192.168.1.161 | LXC  | Serveur MariaDB               |
| 162 | `postgresql` | 192.168.1.162 | LXC  | Serveur PostgreSQL            |
| 203 | `gitlab`     | 192.168.1.203 | VM   | GitLab CE *(hors périmètre IaC pour l'instant)* |

Topologie **éclatée** : le LXC `dbtools` se connecte **à distance** (réseau) à chaque serveur de base, ce qui reproduit un scénario de production et isole les tests par SGBD.

```
                 ┌──────────────┐
                 │   dbtools    │  .160  ── DbToolsBundle (standalone)
                 │  (client)    │
                 └──────┬───────┘
                        │ réseau
            ┌───────────┴───────────┐
            ▼                       ▼
   ┌────────────────┐      ┌──────────────────┐
   │    mariadb     │.161  │   postgresql     │.162
   │  MariaDB 11.8  │      │  PostgreSQL 17   │
   └────────────────┘      └──────────────────┘
```

---

## Prérequis

- Hôte **Proxmox** (`192.168.1.250`, nœud `pve`)
- VM de management `mgmt` (192.168.1.249) avec **OpenTofu**, **Ansible**, et les collections :
  - `community.mysql`
  - `community.postgresql`
- Template LXC : `local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst`
- Token API Proxmox `opentofu@pve!provider` (rôle `OpenTofuProv`)
- Passerelle réseau : **192.168.1.1** — DNS : Pi-hole **192.168.1.151**

---

## Structure du dépôt

```
infra/
├── .env                        # endpoint + token Proxmox (NON versionné)
├── .gitignore
├── opentofu/
│   ├── provider.tf             # provider bpg/proxmox (insecure = true, homelab)
│   ├── variables.tf
│   ├── dbtools-infra.tf        # 3 LXC (for_each) + VM GitLab
│   └── authorized_keys.pub     # 3 clés SSH injectées dans les LXC
└── ansible/
    ├── ansible.cfg
    ├── inventory.ini
    ├── db.yml                  # playbook principal (mariadb + postgresql + dbtools)
    ├── group_vars/
    │   └── all.yml             # secrets, chiffré avec Ansible Vault
    └── roles/
        ├── mariadb/
        ├── postgresql/
        └── dbtools/
```

---

## Secrets

Le mot de passe de la base (`dbtools_db_password`) est stocké **chiffré** dans
`ansible/group_vars/all.yml` via **Ansible Vault**. La passphrase de déverrouillage
est dans `~/.vault_pass` (permissions `600`, jamais versionné), référencée par
`ansible.cfg`.

Ne sont **jamais** versionnés (voir `.gitignore`) :
- `.env` — endpoint et token Proxmox
- `.vault_pass` — passphrase du coffre Vault

Le fichier `group_vars/all.yml` **est** versionné : il est chiffré, donc sans risque.

---

## Utilisation

### Tout construire

```bash
cd ~/infra/opentofu && source ../.env
tofu apply -target='proxmox_virtual_environment_container.db'

cd ~/infra/ansible
ansible-playbook db.yml
```

### Tout détruire et tout reconstruire (démonstration IaC)

```bash
./rebuild.sh
```

Le script enchaîne : destroy → apply → nettoyage known_hosts → contrôle réseau →
playbook Ansible complet → backups de validation sur les deux SGBD.

### Vérifier manuellement

```bash
# Environnement DbToolsBundle
ssh root@192.168.1.160 "cd /opt/dbtools && php vendor/bin/db-tools --version"

# Diagnostic des binaires de dump
ssh root@192.168.1.160 "cd /opt/dbtools && php vendor/bin/db-tools database:check mariadb"
ssh root@192.168.1.160 "cd /opt/dbtools && php vendor/bin/db-tools database:check postgresql"

# Sauvegardes
ssh root@192.168.1.160 "cd /opt/dbtools && php vendor/bin/db-tools database:backup -c mariadb --no-interaction"
ssh root@192.168.1.160 "cd /opt/dbtools && php vendor/bin/db-tools database:backup -c postgresql --no-interaction"
```

Les dumps sont écrits dans `/opt/dbtools/var/<connexion>/AAAA/MM/`.

---

## Choix techniques & pièges résolus

Points non triviaux encodés dans le code (pour mémoire) :

- **TLS** : le certificat auto-signé de Proxmox ne couvre pas l'IP → `insecure = true`
  dans le provider (acceptable en homelab, réseau privé, token scopé).
- **Passerelle** : le réseau utilise **192.168.1.1** (et non `.254`).
- **MAC fixes** : chaque LXC a une MAC statique dans le `.tf`. Sans ça, un rebuild
  change la MAC et la box refuse de router (cache ARP figé sur l'ancienne). Fixer la
  MAC rend le rebuild réellement sans couture.
- **PostgreSQL en LXC** : les conteneurs se connectent en `root` sans `sudo` installé
  → `become_method: su` pour basculer vers l'utilisateur `postgres`.
- **Handlers** : `meta: flush_handlers` force le redémarrage du service *avant* les
  tâches qui ont besoin qu'il écoute sur le réseau (sinon la conf reste non appliquée
  si une tâche échoue en amont).
- **DbToolsBundle + Symfony 8** : la 2.2.1 déclare `symfony/console: ^6|^7|^8` mais son
  code casse en Symfony 8 (`Application::add()` supprimé). Correctif : épingler
  `symfony/console: ^7.0` et installer avec `composer update --with-all-dependencies`.
- **Config standalone** : le `db_tools.config.yaml` en mode standalone n'a **pas** de
  clé racine `db_tools:` — les options (`connections`, `storage`…) sont à la racine.

---

## Reste à faire

- **GitLab (VM 203)** : configuration réseau, installation GitLab CE, enregistrement
  DNS Pi-hole (`gitlab.ambudot.work → .203`), puis pipeline CI/CD d'anonymisation
  via l'image Docker officielle `makinacorpus/dbtoolsbundle`.
- **Anonymiseurs** : ajouter les règles d'anonymisation (config minimale pour l'instant).
- Migration `community.mysql` → `ansible.mysql` (déprécation en v6, non urgent).
