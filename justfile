sudo_flags := env_var_or_default("SUDO_FLAGS", "-K")

default:
    @just --list

check:
    ansible-playbook --syntax-check cluster.yml monitoring.yml verify.yml switchover.yml events.yml power.yml logging.yml zabbix.yml zabbix-config.yml

ping:
    ansible all -i inventory.local.ini -m ansible.builtin.ping

plan:
    ansible-playbook -i inventory.local.ini cluster.yml --check --diff {{sudo_flags}}

apply:
    ansible-playbook -i inventory.local.ini cluster.yml {{sudo_flags}}

monitoring:
    ansible-playbook -i inventory.local.ini monitoring.yml {{sudo_flags}}

logging:
    ansible-playbook -i inventory.local.ini logging.yml {{sudo_flags}}

zabbix:
    ansible-playbook -i inventory.local.ini zabbix.yml {{sudo_flags}}

collections:
    ansible-galaxy collection install -r requirements.yml

zabbix-config:
    ansible-playbook -i inventory.local.ini zabbix-config.yml

verify:
    ansible-playbook -i inventory.local.ini verify.yml {{sudo_flags}}

switchover candidate:
    ansible-playbook -i inventory.local.ini switchover.yml -e candidate={{candidate}} {{sudo_flags}}

events:
    ansible-playbook -i inventory.local.ini events.yml {{sudo_flags}}

stop:
    ansible-playbook -i inventory.local.ini power.yml -e lab_state=stopped {{sudo_flags}}

start:
    ansible-playbook -i inventory.local.ini power.yml -e lab_state=started {{sudo_flags}}
