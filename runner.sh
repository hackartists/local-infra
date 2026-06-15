cd /root
# rustup
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > install.sh
sh install.sh -y

echo '. "$HOME/.cargo/env"' > /root/.bashrc

mkdir -p /root/actions-runner
cd /root/actions-runner

curl -o actions-runner-linux-arm64-2.335.1.tar.gz -L https://github.com/actions/runner/releases/download/v2.335.1/actions-runner-linux-arm64-2.335.1.tar.gz

tar xzf ./actions-runner-linux-arm64-2.335.1.tar.gz
dnf install dotnet-sdk-10.0 -y

# ./bin/installdependencies.sh
./config.sh --url https://github.com/biyard --token $RUNNER_TOKEN --labels $LABELS


./run.sh
