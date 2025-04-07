#!/bin/bash

# Визначення файлу журналу для запису всіх виведених даних
LOGFILE=/var/log/cloud-init-output.log
exec > >(tee -a $LOGFILE) 2>&1

# Файл маркера, щоб скрипт запускався лише один раз
MARKER_FILE="/home/opc/.init_done"

# Перевірка чи існує файл маркера
if [ -f "$MARKER_FILE" ]; then
  echo "Init script has already been run. Exiting."
  exit 0
fi

echo "===== Starting Cloud-Init Script ====="

# Розширення завантажувального обсягу
echo "Expanding boot volume..."
sudo /usr/libexec/oci-growfs -y

# Увімкнення ol8_addons і встановлення необхідних засобів розробки
echo "Installing required packages..."
sudo dnf config-manager --set-enabled ol8_addons
sudo dnf install -y podman git libffi-devel bzip2-devel ncurses-devel readline-devel wget make gcc zlib-devel openssl-devel

# Встановлення бібліотеки SQLite з сайту
echo "Installing latest SQLite..."
cd /tmp
wget https://www.sqlite.org/2023/sqlite-autoconf-3430000.tar.gz
tar -xvzf sqlite-autoconf-3430000.tar.gz
cd sqlite-autoconf-3430000
./configure --prefix=/usr/local
make
sudo make install

# Перевірка встановлення SQLite
echo "SQLite version:"
/usr/local/bin/sqlite3 --version

# Перевіряємо чи правильна версія є на path and globally
export PATH="/usr/local/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
echo 'export PATH="/usr/local/bin:$PATH"' >> /home/opc/.bashrc
echo 'export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"' >> /home/opc/.bashrc

# Встановлення змінних середовища, щоб пов’язати щойно встановлений SQLite зі збіркою Python глобально
echo 'export CFLAGS="-I/usr/local/include"' >> /home/opc/.bashrc
echo 'export LDFLAGS="-L/usr/local/lib"' >> /home/opc/.bashrc

# Отримайте оновлений ~/.bashrc, щоб глобально застосувати зміни
source /home/opc/.bashrc

# Створення постійного каталог для даних Oracle
echo "Creating Oracle data directory..."
sudo mkdir -p /home/opc/oradata
echo "Setting up permissions for the Oracle data directory..."
sudo chown -R 54321:54321 /home/opc/oradata
sudo chmod -R 755 /home/opc/oradata

# Запуск контейнеру Oracle Database Free Edition
echo "Running Oracle Database container..."
sudo podman run -d \
    --name 23ai \
    --network=host \
    -e ORACLE_PWD=database123 \
    -v /home/opc/oradata:/opt/oracle/oradata:z \
    container-registry.oracle.com/database/free:latest

# Чекаємо, доки запуститься контейнер Oracle
echo "Waiting for Oracle container to initialize..."
sleep 10

# Перевірте, чи працює слухач і чи зареєстрована служба freepdb1
echo "Checking if service freepdb1 is registered with the listener..."
while ! sudo podman exec 23ai bash -c "lsnrctl status | grep -q freepdb1"; do
  echo "Waiting for freepdb1 service to be registered with the listener..."
  sleep 30
done
echo "freepdb1 service is registered with the listener."

# Цикл повторних спроб для входу в Oracle із виявленням помилок
MAX_RETRIES=5
RETRY_COUNT=0
DELAY=10

while true; do
  OUTPUT=$(sudo podman exec 23ai bash -c "sqlplus -S sys/database123@localhost:1521/freepdb1 as sysdba <<EOF
EXIT;
EOF")

  if [[ "$OUTPUT" == *"ORA-01017"* || "$OUTPUT" == *"ORA-01005"* ]]; then
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Attempt $RETRY_COUNT: Oracle credential error. Retrying in $DELAY seconds..."
  elif [[ "$OUTPUT" == *"ORA-"* ]]; then
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Attempt $RETRY_COUNT: Oracle connection error. Retrying in $DELAY seconds..."
  else
    echo "Oracle Database is available."
    break
  fi

  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "Max retries reached. Unable to connect to Oracle Database."
    echo "Error output: $OUTPUT"
    exit 1
  fi

  sleep $DELAY
done

# Виконання команд SQL, щоб налаштувати PDB
echo "Configuring Oracle database in PDB (freepdb1)..."
sudo podman exec -i 23ai bash <<EOF
sqlplus -S sys/database123@localhost:1521/freepdb1 as sysdba <<EOSQL
CREATE BIGFILE TABLESPACE tbs2 DATAFILE 'bigtbs_f2.dbf' SIZE 1G AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO;
CREATE UNDO TABLESPACE undots2 DATAFILE 'undotbs_2a.dbf' SIZE 1G AUTOEXTEND ON RETENTION GUARANTEE;
CREATE TEMPORARY TABLESPACE temp_demo TEMPFILE 'temp02.dbf' SIZE 1G REUSE AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1M;
CREATE USER vector IDENTIFIED BY vector DEFAULT TABLESPACE tbs2 QUOTA UNLIMITED ON tbs2;
GRANT DB_DEVELOPER_ROLE TO vector;
EXIT;
EOSQL
EOF

# Повторно підключіться до кореня CDB, щоб застосувати зміни на системному рівні
echo "Switching to CDB root for system-level changes..."
sudo podman exec -i 23ai bash <<EOF
sqlplus -S / as sysdba <<EOSQL
CREATE PFILE FROM SPFILE;
ALTER SYSTEM SET vector_memory_size = 512M SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP;
EXIT;
EOSQL
EOF

# Чекаємо, поки Oracle перезапуститься та застосує зміни пам’яті
sleep 10

echo "Skipping vector_memory_size check. Assuming it is set to 512M based on startup logs."

# Тепер переходимо на opc для налаштування завдань користувача
sudo -u opc -i bash <<'EOF_OPC'

# Встановлення змінних середовища
export HOME=/home/opc
export PYENV_ROOT="$HOME/.pyenv"
curl https://pyenv.run | bash

#Додавання ініціалізації pyenv до ~/.bashrc для opc
cat << EOF >> $HOME/.bashrc
export PYENV_ROOT="\$HOME/.pyenv"
[[ -d "\$PYENV_ROOT/bin" ]] && export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init --path)"
eval "\$(pyenv init -)"
eval "\$(pyenv virtualenv-init -)"
EOF

# Перевіряємо, що джерело .bashrc отримано під час входу
cat << EOF >> $HOME/.bash_profile
if [ -f ~/.bashrc ]; then
   source ~/.bashrc
fi
EOF

# Отримаємо оновлений ~/.bashrc, щоб застосувати зміни pyenv
source $HOME/.bashrc

# Експортуйте шлях, щоб переконатися, що pyenv правильно ініціалізовано
export PATH="$PYENV_ROOT/bin:$PATH"

# Встановіть Python 3.11.9 за допомогою pyenv із пов’язаною правильною версією SQLite
CFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib" LD_LIBRARY_PATH="/usr/local/lib" pyenv install 3.11.9

# Повторили pyenv, для оновлення
pyenv rehash

# Налаштування каталогу векторів і середовища Python 3.11.9
mkdir -p $HOME/AI_documents
cd $HOME/AI_documents
pyenv local 3.11.9

pyenv rehash

# Перевіримо версію Python у каталозі 
python --version

# Додавання PYTHONPATH для правильного встановлення та пошуку бібліотек
export PYTHONPATH=$HOME/.pyenv/versions/3.11.9/lib/python3.11/site-packages:$PYTHONPATH

# Встановлення необхідих пакетів Python
$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir oci==2.129.1 oracledb sentence-transformers langchain==0.2.6 langchain-community==0.2.6 langchain-chroma==0.1.2 langchain-core==0.2.11 langchain-text-splitters==0.2.2 langsmith==0.1.83 pypdf==4.2.0 streamlit==1.36.0 python-multipart==0.0.9 chroma-hnswlib==0.7.3 chromadb==0.5.3 torch==2.5.0

# Завантажуєм модель під час виконання скрипту
python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L12-v2')"

# Встановлення JupyterLab
pip install --user jupyterlab

#  Встановлення OCI CLI
echo "Installing OCI CLI..."
curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o install.sh
chmod +x install.sh
./install.sh --accept-all-defaults

# Перевірка встановлення
echo "Verifying OCI CLI installation..."
oci --version || { echo "OCI CLI installation failed."; exit 1; }

# Переконаємось, що всі двійкові файли додано до PATH
echo 'export PATH=$PATH:$HOME/.local/bin' >> $HOME/.bashrc
source $HOME/.bashrc

# Скопіюєм файли з папки git repo AI_documents до каталогу AI_documents в екземплярі
echo "Copying files from the 'AI_documents' folder in the OU Git repository to the existing AI_documents directory..."
REPO_URL="https://github.com/Botvynko/AIdatabase.git"
FINAL_DIR="$HOME/AI_documents"  # Existing directory on your instance

# ініціалізуємо новий git репозиторій
git init

# Додаємо віддалений репозиторій
git remote add origin $REPO_URL

# Увімкнемо sparse-checkout і вкажемо папку для завантаження
git config core.sparseCheckout true
echo "AI_documents/*" >> .git/info/sparse-checkout

# Витягніть лише вказану папку в існуючому каталозі
git pull origin main  # Replace 'main' with the correct branch name if necessary

# Move the contents of the 'AI_documents' subfolder to the root of FINAL_DIR, if necessary
mv AI_documents/* . 2>/dev/null || true  # Move files if 'AI_documents' folder exists

# Видалення будь-який порожніх каталогів і папку .git
rm -rf .git AI_documents

echo "Files successfully downloaded to $FINAL_DIR"

EOF_OPC

# Створимо файл маркера, щоб вказати, що скрипт запущено
touch "$MARKER_FILE"

echo "===== Cloud-Init Script Completed Successfully ====="
exit 0
