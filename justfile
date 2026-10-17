sudo_flags := "-K"

default:
    @just --list

check:
    ansible-playbook --syntax-check cluster.yml monitoring.yml verify.yml switchover.yml events.yml power.yml

ping:
    ansible all -i inventory.local.ini -m ansible.builtin.ping

plan:
    ansible-playbook -i inventory.local.ini cluster.yml --check --diff {{sudo_flags}}

apply:
    ansible-playbook -i inventory.local.ini cluster.yml {{sudo_flags}}

monitoring:
    ansible-playbook -i inventory.local.ini monitoring.yml {{sudo_flags}}

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
