#!/bin/bash
set -e

echo "🚀 Init Ansible Runner..."

mkdir -p /dev/shm/.ssh
chmod 700 /dev/shm/.ssh

# Store Vault pass to shm
if [ -n "$ANSIBLE_VAULT_PASSWORD" ]; then
    VAULT_PASS_FILE="/dev/shm/.vault_password"
    echo -n "$ANSIBLE_VAULT_PASSWORD" > "$VAULT_PASS_FILE"
    chmod 600 "$VAULT_PASS_FILE"
    export ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PASS_FILE"
    echo "✅ vault pass ready (/dev/shm) from env"
elif [ -f /run/secrets/vault_password ]; then
    VAULT_PASS_FILE="/dev/shm/.vault_password"
    cp /run/secrets/vault_password "$VAULT_PASS_FILE"
    chmod 600 "$VAULT_PASS_FILE"
    export ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PASS_FILE"
    echo "✅ vault pass ready (/dev/shm) from secret"
else
    echo "⚠️ ANSIBLE_VAULT_PASSWORD not set"
fi

# Prepare ssh key
if [ -f ./.ssh/ssh_key.vault ]; then
    uv run ansible-vault decrypt ./.ssh/ssh_key.vault \
        --output /dev/shm/.ssh/ssh_key
    chmod 600 /dev/shm/.ssh/ssh_key
    export ANSIBLE_PRIVATE_KEY_FILE=/dev/shm/.ssh
elif [ -f /run/secrets/ssh_key_vault ]; then
    echo "🔓 Decrypt ssh key from secrets..."
    uv run ansible-vault decrypt /run/secrets/ssh_key_vault \
        --output /dev/shm/.ssh/ssh_key
    chmod 600 /dev/shm/.ssh/ssh_key
    export ANSIBLE_PRIVATE_KEY_FILE=/dev/shm/.ssh
fi

# Install additional Ansible-collections if ansible/collections/requirements.yml is present
if [ -f ansible/collections/requirements.yml ]; then
    echo "📚 Install Ansible-collections..."
    uv run ansible-galaxy collection install -r ansible/collections/requirements.yml
fi

echo "✅ Init finished..."
cd ansible

COMMAND=${1:-default}
shift || true # remove first arg from "$@"

case "$COMMAND" in
    lint)
        TARGET=${1:-.}
        echo "🔍 Run ansible-lint on ${TARGET} dir..."
        shift || true
        exec uv run ansible-lint "$TARGET" "$@"
        ;;
        
    encrypt)
        if [ -z "$1" ]; then
            echo "❌ Error: file path required"
            echo "   Example: encrypt inventory/group_vars/all"
            echo "   Note: to define destination name use: encrypt source.yml --output target.yml"
            exit 1
        fi
        
        if [ -z "$ANSIBLE_VAULT_PASSWORD_FILE" ] || [ ! -f "$ANSIBLE_VAULT_PASSWORD_FILE" ]; then
            echo "❌ Error: no vault key provided"
            exit 1
        fi

        SOURCE_FILE="$1"
        shift || true
        
        HAS_OUTPUT=false
        for arg in "$@"; do
            if [[ "$arg" == "--output" || "$arg" == "-o" || "$arg" == --output=* || "$arg" == -o=* ]]; then
                HAS_OUTPUT=true
                break
            fi
        done

        if [ "$HAS_OUTPUT" = false ]; then
            # If target is not set, prepare target file name
            if [[ "$SOURCE_FILE" == *.yml || "$SOURCE_FILE" == *.yaml ]]; then
                # For yml/yaml add .vault before extension
                OUTPUT_FILE="${SOURCE_FILE%.*}.vault.yml"
            else
                # Or just add .yml
                OUTPUT_FILE="${SOURCE_FILE}.yml"
            fi
            echo "🔒 Encrypt: $SOURCE_FILE -> $OUTPUT_FILE"
            exec uv run ansible-vault encrypt "$SOURCE_FILE" --output "$OUTPUT_FILE" "$@"
        else
            echo "🔒 Encrypt: $SOURCE_FILE (with defined target)"
            exec uv run ansible-vault encrypt "$SOURCE_FILE" "$@"
        fi
        ;;        
    play)
        if [ -z "$1" ]; then
            echo "❌ Error: playbook name required"
            echo "   Example: play site.yml -e 'env=prod'"
            exit 1
        fi
        
        PLAYBOOK="$1"
        shift || true
        echo "▶️ Run playbook: $PLAYBOOK"
        echo "   exta params: $*"
        exec uv run ansible-playbook "$PLAYBOOK" "$@"
        ;;
        
    genkey)
        if [ -z "$ANSIBLE_VAULT_PASSWORD_FILE" ] || [ ! -f "$ANSIBLE_VAULT_PASSWORD_FILE" ]; then
            echo "❌ Error: no vault key provided" >&2
            exit 1
        fi

        TEMP_KEY="/dev/shm/ansible_gen_ssh_key"
        rm -f "$TEMP_KEY" "$TEMP_KEY.pub" "$TEMP_KEY.vault"

        echo "🔑 Generating SSH key..." >&2
        ssh-keygen -t ed25519 -f "$TEMP_KEY" -N "" -q "$@" -C "ansible_user"
        
        if [ ! -f "$TEMP_KEY" ]; then
            echo "❌ Error: can not generate SSH key" >&2
            exit 1
        fi

        echo "🔒 Encrypting private key with Ansible Vault..." >&2
        uv run ansible-vault encrypt "$TEMP_KEY" \
            --output "$TEMP_KEY.vault"

        echo "================================================" >&2
        echo "✅ Public key (add to authorized_keys):" >&2
        echo "------------------------------------------------" >&2
        cat "$TEMP_KEY.pub" >&2
        echo "" >&2
        echo "✅ Encrypted private key:" >&2
        echo "------------------------------------------------" >&2
        cat "$TEMP_KEY.vault"
        
        rm -f "$TEMP_KEY" "$TEMP_KEY.pub" "$TEMP_KEY.vault"
        ;;

    default|*)
        echo "⚙️ Run custom command: $COMMAND $*"
        exec "$COMMAND" "$@"
        ;;
esac
