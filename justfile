sudo_flags := env_var_or_default("SUDO_FLAGS", "-K")

default:
    @just --list

check:
    ansible-playbook --syntax-check cluster.yml monitoring.yml verify.yml switchover.yml events.yml power.yml logging.yml zabbix.yml zabbix-config.yml

ping:
    ansible all -i inventory.local.ini -m ansible.builtin.ping

plan cluster="":
    ansible-playbook -i inventory.local.ini cluster.yml --check --diff {{ if cluster == "" { "" } else { "-e cluster=" + cluster } }} {{sudo_flags}}

apply cluster="":
    ansible-playbook -i inventory.local.ini cluster.yml {{ if cluster == "" { "" } else { "-e cluster=" + cluster } }} {{sudo_flags}}

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

verify cluster="":
    ansible-playbook -i inventory.local.ini verify.yml {{ if cluster == "" { "" } else { "-e cluster=" + cluster } }} {{sudo_flags}}

switchover candidate cluster="":
    ansible-playbook -i inventory.local.ini switchover.yml -e candidate={{candidate}} {{ if cluster == "" { "" } else { "-e cluster=" + cluster } }} {{sudo_flags}}

events cluster="":
    ansible-playbook -i inventory.local.ini events.yml {{ if cluster == "" { "" } else { "-e cluster=" + cluster } }} {{sudo_flags}}

stop cluster="":
    ansible-playbook -i inventory.local.ini power.yml -e lab_state=stopped {{ if cluster == "" { "" } else { "-e cluster=" + cluster } }} {{sudo_flags}}

start cluster="":
    ansible-playbook -i inventory.local.ini power.yml -e lab_state=started {{ if cluster == "" { "" } else { "-e cluster=" + cluster } }} {{sudo_flags}}
