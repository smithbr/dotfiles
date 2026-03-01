#!/bin/bash

echo "🔍 Checking for existing GitHub SSH connection..."
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    echo "✅ Already authenticated with GitHub — no setup needed"
    exit 0
fi

EMAIL="1495361+smithbr@users.noreply.github.com"
KEY="$HOME/.ssh/id_ed25519"

echo "🔑 Generating SSH key for $EMAIL..."
ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY"

echo "📋 Adding key to ssh-agent..."
ssh-add "$KEY"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Your public key:"
echo ""
cat "$KEY.pub"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "👆 Copy the key above and add it at:"
echo "   https://github.com/settings/keys"
echo ""
read -p "Press enter when done (Ctrl+C to cancel)..."

echo ""
echo "🔗 Testing connection to GitHub..."
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    echo "✅ Success!"
else
    echo "❌ Something went wrong. Check your key was added correctly."
fi
