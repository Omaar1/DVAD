# vagrant plugin install vagrant-windows-sysprep

require 'json'

# Emit the standard shell provisioner: run <script> (plus optional space-separated args)
# through the invoke-vagrant-script.ps1 wrapper, which supplies the Stop/trap/Exit-1
# contract so a failed step actually halts provisioning. Pass reboot: true to append a reboot.
def phase(config, script, args = "", reboot: false)
  config.vm.provision "shell",
    path: "provisioners/invoke-vagrant-script.ps1",
    args: "#{script} #{args}".strip
  config.vm.provision "shell", reboot: true if reboot
end

# Single source of truth: all hostnames, IPs, box, and resources come from
# inventory/lab-config.json (the PowerShell scripts read the same file
# via get-lab-config.ps1). Edit the JSON, not this file, to retune the lab.
cfg = JSON.parse(File.read(File.join(File.dirname(__FILE__), 'inventory', 'lab-config.json')))

box_name    = cfg['box']['name']
box_version = cfg['box']['version']
hosts       = cfg['hosts']

Vagrant.configure("2") do |cfg_vm|

    cfg_vm.vm.boot_timeout = 900

    rootdc = hosts['rootdc']
    childdc = hosts['childdc']
    adcs   = hosts['adcs']
    sccm   = hosts['sccm']
    svr1   = hosts['svr1']

    #This is a domain controller with standard configuration.
    #It creates a single forest and populates the domain with AD objects like users and groups.
    #It can also create specific GPOs and serve as DNS server.

    cfg_vm.vm.define "DVAD-DC" do |config|
      config.vm.box = box_name
      config.vm.box_version = box_version
      config.vm.hostname = rootdc['name']

      # Use the plaintext WinRM transport and force it to use basic authentication.
      # NB this is needed because the default negotiate transport stops working
      # after the domain controller is installed.
      # see https://groups.google.com/forum/#!topic/vagrant-up/sZantuCM0q4
      config.winrm.transport = :plaintext
      config.winrm.basic_auth_only = true
      config.winrm.retry_limit = 30
      config.winrm.retry_delay = 10

      config.vm.provider :virtualbox do |v, override|
        v.name = rootdc['name']
        v.linked_clone = true
        v.gui = false
        v.cpus = rootdc['cpus']
        v.memory = rootdc['memory']
        v.customize ["modifyvm", :id, "--vram", 64]
      end

      config.vm.network :private_network,
        :ip => rootdc['ip']

      # Configure keyboard/language/timezone etc.
      phase config, "provisioners/host/prepare-host.ps1"
      # Disable License service to prevent machines from automatic shutdown.
      phase config, "provisioners/host/disable-license-service.ps1", reboot: true


      # # # # Create forest root
      phase config, "provisioners/domain/deploy-forest.ps1", reboot: true

      # Configure the Root DC DNS server now that the forest (and its zones) exist.
      phase config, "provisioners/net/configure-network.ps1", "RootDcDns"

      phase config, "provisioners/domain/seed-directory.ps1", "lab-users.json"

      # Extend the AD schema with the legacy LAPS attributes (official AdmPwd.PS
      # module). Runs on the schema master; SVR1's ms-Mcs-AdmPwd value is planted
      # later by configure-machine-attacks.ps1 once SVR1 has joined.
      phase config, "provisioners/domain/install-laps-schema.ps1"

      # Anonymous LDAP bind + Account Operators SDProp-exclusion (dSHeuristics) and the
      # ANONYMOUS LOGON read grant must run BEFORE attack-path ACEs are written, so the
      # Ch2 GenericWrite ACE on r.chen (an Account Operators member) survives SDProp.
      phase config, "provisioners/tools/enable-anonymous-bind.ps1"

      phase config, "provisioners/domain/configure-attack-paths.ps1"

      # Pre-stage SVR1$/ADCS$ computer accounts and apply Chain 6/7 (delegation, RBCD,
      # LAPS) up front. The real machines join later and reuse these accounts; the ACEs
      # and attributes survive the join (server1 only re-asserts SVR1's delegation flag).
      phase config, "provisioners/domain/prestage-machine-attacks.ps1"

      # Chain 3 (GPP cpassword in SYSVOL) and Chain 4 (GPO abuse: Project-Phoenix gets
      # edit on a DC-linked GPO). Both create GPOs / write SYSVOL, so they run after the
      # AD objects and ACEs exist.
      phase config, "provisioners/domain/configure-chain3-gpp.ps1"
      phase config, "provisioners/domain/configure-chain4-gpo.ps1"

      # SMB null-session enumeration. Applied before the final reboot so the LSA/SMB
      # registry changes take effect.
      phase config, "provisioners/tools/enable-null-session.ps1"

      # Final reboot to settle configuration
      config.vm.provision "shell", reboot: true

    end




    cfg_vm.vm.define "CA01" do |config|
      config.vm.box = box_name
      config.vm.box_version = box_version
      config.vm.hostname = adcs['name']

      # Use the plaintext WinRM transport and force it to use basic authentication.
      # NB this is needed because the default negotiate transport stops working
      # after the domain controller is installed.
      # see https://groups.google.com/forum/#!topic/vagrant-up/sZantuCM0q4
      config.winrm.transport = :plaintext
      config.winrm.basic_auth_only = true
      config.winrm.retry_limit = 30
      config.winrm.retry_delay = 10

      config.vm.provider :virtualbox do |v, override|
        v.name = adcs['name']
        v.linked_clone = true  # saves ~30 GB disk per VM vs full clone
        v.gui = false
        v.cpus = adcs['cpus']
        v.memory = adcs['memory']
        v.customize ["modifyvm", :id, "--vram", 64]
      end

      config.vm.network :private_network,
        :ip => adcs['ip']

      config.vm.provision "windows-sysprep"
      config.vm.provision "shell", reboot: true
      # Configure keyboard/language/timezone etc.
      phase config, "provisioners/host/prepare-host.ps1"

      # Disable License service to prevent machines from automatic shutdown.
      phase config, "provisioners/host/disable-license-service.ps1"

      # # # Configure DNS
      #Join the domain specified in provided variables file - Only do this after everything else has been installed
      phase config, "provisioners/domain/add-to-domain.ps1", reboot: true

      # Install ActiveDirectory Certificate Services (ESC1-ESC8 vulnerable templates).
      # No reboot here - the MemberDns step needs none, so one reboot covers both.
      phase config, "provisioners/services/ADCS/install-adcs.ps1"

      phase config, "provisioners/net/configure-network.ps1", "MemberDns", reboot: true


    end



    cfg_vm.vm.define "CM01" do |config|
      config.vm.box = box_name
      config.vm.box_version = box_version
      config.vm.hostname = sccm['name']

      # Use the plaintext WinRM transport and force it to use basic authentication.
      # NB this is needed because the default negotiate transport stops working
      # after the domain controller is installed.
      # see https://groups.google.com/forum/#!topic/vagrant-up/sZantuCM0q4
      config.winrm.transport = :plaintext
      config.winrm.basic_auth_only = true
      config.winrm.retry_limit = 30
      config.winrm.retry_delay = 10

      config.vm.provider :virtualbox do |v, override|
        v.name = sccm['name']
        v.linked_clone = true
        v.gui = false
        v.cpus = sccm['cpus']
        v.memory = sccm['memory']
        v.customize ["modifyvm", :id, "--vram", 64]
      end

      config.vm.network :private_network,
        :ip => sccm['ip']

      # ========================================================================
      # PHASE 1: INITIAL SYSTEM SETUP
      # ========================================================================


      # Sysprep: Generate unique SID (required for domain join, prevents SID conflicts)
      config.vm.provision "windows-sysprep"
      config.vm.provision "shell", reboot: true

      # Configure regional settings: keyboard layout, language, timezone
      phase config, "provisioners/host/prepare-host.ps1"

      # Disable Windows license service to prevent automatic VM shutdown after 180 days
      phase config, "provisioners/host/disable-license-service.ps1"

      # ========================================================================
      # PHASE 2: DOMAIN JOIN
      # ========================================================================

      # Join the SCCM server to the domain (credentials come from lab-config.json)
      phase config, "provisioners/domain/add-to-domain.ps1", reboot: true

      # ========================================================================
      # PHASE 3: SCCM PREREQUISITES
      # ========================================================================

      # Create required AD accounts for SCCM: sccm_admin, sccm_naa, sccm_cp, sccm_dj
      phase config, "provisioners/services/SCCM/prepare-sccm-accounts.ps1"

      # Install Windows Server roles/features required by SCCM:
      # - IIS, BITS, RDC, .NET Framework 3.5, Remote Differential Compression
      phase config, "provisioners/services/SCCM/install-dep-roles.ps1"

      # Install Windows Assessment and Deployment Kit (ADK):
      # - Required for OS deployment, boot images, and USMT
      phase config, "provisioners/services/SCCM/install-adk.ps1", reboot: true

      # ========================================================================
      # PHASE 4: SQL SERVER INSTALLATION
      # ========================================================================

      # Install SQL Server 2019 with SCCM-compatible configuration:
      # - Mixed mode authentication, required collation, memory settings
      phase config, "provisioners/services/SCCM/install-sql.ps1", reboot: true

      # ========================================================================
      # PHASE 5: MECM (SCCM) INSTALLATION
      # ========================================================================

      # Install Microsoft Endpoint Configuration Manager (MECM/SCCM):
      # - Primary site installation with site code PS1
      # - Configures Management Point, Distribution Point, and other roles
      phase config, "provisioners/services/SCCM/install-mecm.ps1"

      # Configure SCCM console permissions and Role-Based Access Control (RBAC):
      # - Adds DVAD\Administrator and DVAD\SCCMAdmin to SMS Admins group
      # - Grants Full Administrator role in SCCM
      phase config, "provisioners/services/SCCM/repair-sccm-permissions.ps1", reboot: true

      # ========================================================================
      # PHASE 6: VULNERABLE CONFIGURATION (CRED-1 ATTACK PATH)
      # ========================================================================

      # Configure VULNERABLE SCCM PXE boot for CRED-1 attack simulation:
      # - Enables PXE without password protection
      # - Creates boot images and task sequence for OS deployment
      # - Deploys task sequence to All Systems collection
      # The four configure-vuln-* scripts below are pure SCCM-console operations (boundaries, TS,
      # client push, package). They need no reboot between them; the site stays up and
      # each reconnects to the provider on its own.
      phase config, "provisioners/services/SCCM/configure-vuln-pxe.ps1"

      # ========================================================================
      # PHASE 7: VULNERABLE CONFIGURATION (CRED-2 ATTACK PATH)
      # ========================================================================
      # - Deploys task sequence to All Systems collection
      phase config, "provisioners/services/SCCM/configure-vuln-ts-variables.ps1"

      # ========================================================================
      # PHASE 8: VULNERABLE CLIENT PUSH Installation
      # ========================================================================

      # Configure VULNERABLE SCCM client push for CRED-3 attack simulation:
      # - Enables client push installation
      # - Configures client push for all systems
      # - Adds DVAD\sccm_cpia to client push account
      phase config, "provisioners/services/SCCM/configure-vuln-client-push.ps1"

      # ========================================================================
      # PHASE 9: VULNERABLE DISTRIBUTION POINT (Anon DP LOOTING)
      # ========================================================================
      # - Deploys a vulnerable package to All Systems collection
      phase config, "provisioners/services/SCCM/configure-vuln-app-package.ps1"

      # configure network
      phase config, "provisioners/net/configure-network.ps1", "MemberDns", reboot: true


    end




  #   # HQ-DC: child domain controller (hq.dvad.lab) under the dvad.lab forest root.
  #   # Creates the child domain and populates it with AD objects like users and groups.
  #   # It can also create specific GPOs and serve as DNS server.
  #   # STUB: defined in lab-config.json (childDomain + hosts.childdc) but NOT built yet.
  #   # Un-comment this block to provision the child domain / cross-domain trust scenarios.
  #   cfg_vm.vm.define "HQ-DC" do |config|
  #     config.vm.box = box_name
  #     config.vm.box_version = box_version
  #     config.vm.hostname = childdc['name']

  #     # Use the plaintext WinRM transport and force it to use basic authentication.
  #     # NB this is needed because the default negotiate transport stops working
  #     #    after the domain controller is installed.
  #     #    see https://groups.google.com/forum/#!topic/vagrant-up/sZantuCM0q4
  #     config.winrm.transport = :plaintext
  #     config.winrm.basic_auth_only = true
  #     config.winrm.retry_limit = 30
  #     config.winrm.retry_delay = 10

  #     config.vm.provider :virtualbox do |v, override|
  #         v.name = childdc['name']
  #         v.linked_clone = true  # <--- THIS SAVES 30GB+ across the lab
  #         v.gui = false
  #         v.cpus = childdc['cpus']
  #         v.memory = childdc['memory']
  #         v.customize ["modifyvm", :id, "--vram", 64]
  #     end

  #     config.vm.network :private_network,
  #         :ip => childdc['ip']

  #     # #https://github.com/rgl/vagrant-windows-sysprep  ## Without it ALL MACHINES gonna have same SID -__-
  #     config.vm.provision "windows-sysprep"
  #     config.vm.provision "shell", reboot: true

  #     # Configure keyboard/language/timezone/Firewall etc.
  #     phase config, "provisioners/host/prepare-host.ps1"

  #     # Disable License service to prevent machines from automatic shutdown.
  #     phase config, "provisioners/host/disable-license-service.ps1", reboot: true


  #     # Create child domain
  #     phase config, "provisioners/domain/deploy-child-domain.ps1", reboot: true

  #     # Configure DNS
  #     phase config, "provisioners/net/configure-network.ps1", "MemberDns", reboot: true
  # end



    # ========================================================================
    # SRV01 (Generic Member Server)
    # Domain-joined Windows Server used for lateral movement, delegation,
    # LAPS, and privilege escalation exercises.
    # ========================================================================
    cfg_vm.vm.define "SRV01" do |config|
      config.vm.box = box_name
      config.vm.box_version = box_version
      config.vm.hostname = svr1['name']

      config.winrm.transport = :plaintext
      config.winrm.basic_auth_only = true
      config.winrm.retry_limit = 30
      config.winrm.retry_delay = 10

      config.vm.provider :virtualbox do |v, override|
          v.name = svr1['name']
          v.linked_clone = true
          v.gui = false
          v.cpus = svr1['cpus']
          v.memory = svr1['memory']
          v.customize ["modifyvm", :id, "--vram", 64]
      end

      config.vm.network :private_network,
          :ip => svr1['ip']

      # Generate unique SID
      config.vm.provision "windows-sysprep"
      config.vm.provision "shell", reboot: true

      # Configure regional settings
      phase config, "provisioners/host/prepare-host.ps1"

      # Disable License service
      phase config, "provisioners/host/disable-license-service.ps1"

      # Join the domain (prepare-host + disable-license need no reboot first; one
      # reboot here applies the SID/regional/license changes together, like ADCS)
      phase config, "provisioners/domain/add-to-domain.ps1", reboot: true

      # Configure DNS
      phase config, "provisioners/net/configure-network.ps1", "MemberDns", reboot: true

      # Apply machine-dependent attack paths (delegation, LAPS, RBCD)
      # Runs last because it needs SRV01 and CA01 computer objects to exist in AD
      phase config, "provisioners/domain/configure-machine-attacks.ps1", reboot: true

    end



    # ========================================================================
    # SQL01 (Standalone MSSQL Member Server) -- STUB / NOT BUILT YET
    # Defined in lab-config.json (hosts.mssql) so it can be referenced now and
    # built later. Un-comment and add the SQL install provisioning to bring it up.
    # When SQL01 goes live, move the svc_sqldb SPN (MSSQLSvc/SRV01.dvad.lab:1433)
    # in lab-users.json onto SQL01.dvad.lab.
    # ========================================================================
    # cfg_vm.vm.define "SQL01" do |config|
    #   sql = hosts['mssql']
    #   config.vm.box = box_name
    #   config.vm.box_version = box_version
    #   config.vm.hostname = sql['name']
    #
    #   config.winrm.transport = :plaintext
    #   config.winrm.basic_auth_only = true
    #   config.winrm.retry_limit = 30
    #   config.winrm.retry_delay = 10
    #
    #   config.vm.provider :virtualbox do |v, override|
    #       v.name = sql['name']
    #       v.linked_clone = true
    #       v.gui = false
    #       v.cpus = sql['cpus']
    #       v.memory = sql['memory']
    #       v.customize ["modifyvm", :id, "--vram", 64]
    #   end
    #
    #   config.vm.network :private_network,
    #       :ip => sql['ip']
    #
    #   # Generate unique SID
    #   config.vm.provision "windows-sysprep"
    #   config.vm.provision "shell", reboot: true
    #
    #   # Configure regional settings + disable license service
    #   phase config, "provisioners/host/prepare-host.ps1"
    #   phase config, "provisioners/host/disable-license-service.ps1"
    #
    #   # Join the domain
    #   phase config, "provisioners/domain/add-to-domain.ps1", reboot: true
    #
    #   # Configure DNS
    #   phase config, "provisioners/net/configure-network.ps1", "MemberDns", reboot: true
    #
    #   # TODO: install SQL Server (see provisioners/services/SCCM/install-sql.ps1 for a reference)
    # end

end
