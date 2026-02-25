# vagrant plugin install vagrant-windows-sysprep


Vagrant.configure("2") do |cfg|

    fqdn = "silent.run"
    root_netbios = "SILENT"

    ad_fqdn = "something.silent.run"
    ad_netbios = "SOMETHING"

    rootdc_name = "ROOTDC"
    rootdc_ip = "10.10.10.100"

    dc_name = "CHILDDC"
    dc_ip = "10.10.10.101"

    ADCS_name = "ADCS"
    ADCS_ip = "10.10.10.103"

    SCCM_name = "SCCM"
    SCCM_ip = "10.10.10.104"

    server_name = "SVR1"
    server_ip = "10.10.10.150"

    # wks_name = "WRK1"
    # wks_ip = "10.10.10.200"

    #This is a domain controller with standard configuration. 
    #It creates a single forest and populates the domain with AD objects like users and groups. 
    #It can also create specific GPOs and serve as DNS server.

    cfg.vm.define "RootDC" do |config|
      config.vm.box = "StefanScherer/windows_2019"
      config.vm.box_version = "2018.10.03"
      config.vm.hostname = rootdc_name

      # Use the plaintext WinRM transport and force it to use basic authentication.
      # NB this is needed because the default negotiate transport stops working
      # after the domain controller is installed.
      # see https://groups.google.com/forum/#!topic/vagrant-up/sZantuCM0q4
      config.winrm.transport = :plaintext
      config.winrm.basic_auth_only = true
      config.winrm.retry_limit = 30
      config.winrm.retry_delay = 10
      
      config.vm.provider :virtualbox do |v, override|
        v.name = rootdc_name
        v.linked_clone = true
        v.gui = false
        v.cpus = 2
        v.memory = 2048
        v.customize ["modifyvm", :id, "--vram", 64]
      end
      
      config.vm.network :private_network,
        :ip => rootdc_ip

      # Configure keyboard/language/timezone etc.
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/windows/provision-base.ps1"
      # config.vm.provision "shell", reboot: true
      # Disable License service to prevent machines from automatic shutdown.
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/windows/disable-license-service.ps1"
      config.vm.provision "shell", reboot: true
      
      
      # # # Configure DNS
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/networking/network-setup.ps1 network-setup-rootdc.ps1 root_dns_entries.csv"
      config.vm.provision "shell", reboot: true

      # # # # Create forest root
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/ad/install-forest.ps1 forest-variables.json"
      config.vm.provision "shell", reboot: true

      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/ad/create-ad-objects.ps1 forest-variables.json planned-users.json"


      # #Reboot so that scheduled task runs
      config.vm.provision "shell", reboot: true

    end




    cfg.vm.define "ADCS_server" do |config|
      config.vm.box = "StefanScherer/windows_2019"
      config.vm.box_version = "2018.10.03"
      config.vm.hostname = ADCS_name

      # Use the plaintext WinRM transport and force it to use basic authentication.
      # NB this is needed because the default negotiate transport stops working
      # after the domain controller is installed.
      # see https://groups.google.com/forum/#!topic/vagrant-up/sZantuCM0q4
      config.winrm.transport = :plaintext
      config.winrm.basic_auth_only = true
      config.winrm.retry_limit = 30
      config.winrm.retry_delay = 10
      
      config.vm.provider :virtualbox do |v, override|
        v.name = ADCS_name
        v.linked_clone = true  # <--- THIS SAVES 30GB+ across the lab
        v.gui = false
        v.cpus = 1
        v.memory = 1024
        v.customize ["modifyvm", :id, "--vram", 64]
      end
      
      config.vm.network :private_network,
        :ip => ADCS_ip

      config.vm.provision "windows-sysprep"
      config.vm.provision "shell", reboot: true
      # Configure keyboard/language/timezone etc.
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/windows/provision-base.ps1"

      # Disable License service to prevent machines from automatic shutdown.
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/windows/disable-license-service.ps1"  
      
      # # # Configure DNS
      #Join the domain specified in provided variables file - Only do this after everything else has been installed
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/ad/join-domain.ps1 forest-variables.json"
      config.vm.provision "shell", reboot: true

      # Install ActiveDirectory Certificate Services
      # config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/services/ADCS/runasAdmin.ps1 forest-variables.json"
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/networking/network-setup.ps1"

      config.vm.provision "shell", reboot: true


    end



    cfg.vm.define "SCCM_server" do |config|
      config.vm.box = "StefanScherer/windows_2019"
      config.vm.box_version = "2018.10.03"
      config.vm.hostname = SCCM_name

      # Use the plaintext WinRM transport and force it to use basic authentication.
      # NB this is needed because the default negotiate transport stops working
      # after the domain controller is installed.
      # see https://groups.google.com/forum/#!topic/vagrant-up/sZantuCM0q4
      config.winrm.transport = :plaintext
      config.winrm.basic_auth_only = true
      config.winrm.retry_limit = 30
      config.winrm.retry_delay = 10
      
      config.vm.provider :virtualbox do |v, override|
        v.name = SCCM_name
        v.linked_clone = true
        v.gui = false
        v.cpus = 2
        v.memory = 8192 
        v.customize ["modifyvm", :id, "--vram", 64]
      end
      
      config.vm.network :private_network,
        :ip => SCCM_ip

      # ========================================================================
      # PHASE 1: INITIAL SYSTEM SETUP
      # ========================================================================
      
      # Sysprep: Generate unique SID (required for domain join, prevents SID conflicts)
      config.vm.provision "windows-sysprep"
      config.vm.provision "shell", reboot: true
      
      # Configure regional settings: keyboard layout, language, timezone
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/windows/provision-base.ps1"

      # Disable Windows license service to prevent automatic VM shutdown after 180 days
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/windows/disable-license-service.ps1"  
      
      # ========================================================================
      # PHASE 2: DOMAIN JOIN
      # ========================================================================
      
      # Join the SCCM server to SILENT.silent.run domain (uses forest-variables.json for credentials)
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/ad/join-domain.ps1 forest-variables.json"
      config.vm.provision "shell", reboot: true

      # # ========================================================================
      # # PHASE 3: SCCM PREREQUISITES
      # # ========================================================================
      
      # # Create required AD accounts for SCCM: sccm_admin, sccm_naa, sccm_cp, sccm_dj
      # # These accounts are used for various SCCM operations and client push
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/services/SCCM/prepareSccmAccounts.ps1 forest-variables.json"
      
      # Install Windows Server roles/features required by SCCM:
      # - IIS, BITS, RDC, .NET Framework 3.5, Remote Differential Compression
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/services/SCCM/installDepRoles.ps1"
      
      # Install Windows Assessment and Deployment Kit (ADK):
      # - Required for OS deployment, boot images, and USMT
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/services/SCCM/installADK.ps1"
      config.vm.provision "shell", reboot: true
      
      # ========================================================================
      # PHASE 4: SQL SERVER INSTALLATION
      # ========================================================================
      
      # Install SQL Server 2019 with SCCM-compatible configuration:
      # - Mixed mode authentication, required collation, memory settings
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/services/SCCM/installSQL.ps1"
      config.vm.provision "shell", reboot: true

      # ========================================================================
      # PHASE 5: MECM (SCCM) INSTALLATION
      # ========================================================================
      
      # Install Microsoft Endpoint Configuration Manager (MECM/SCCM):
      # - Primary site installation with site code PS1
      # - Configures Management Point, Distribution Point, and other roles
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/services/SCCM/installMECM.ps1"
      
      # Configure SCCM console permissions and Role-Based Access Control (RBAC):
      # - Adds SILENT\Administrator and SILENT\SCCMAdmin to SMS Admins group
      # - Grants Full Administrator role in SCCM
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/services/SCCM/fixSccmPermissions.ps1"
      config.vm.provision "shell", reboot: true

      # ========================================================================
      # PHASE 6: VULNERABLE CONFIGURATION (CRED-1 ATTACK PATH)
      # ========================================================================
      
      # Configure VULNERABLE SCCM PXE boot for CRED-1 attack simulation:
      # - Enables PXE without password protection
      # - Creates boot images and task sequence for OS deployment
      # - Deploys task sequence to All Systems collection
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/services/SCCM/Vuln-NAA-PXE.ps1"
      config.vm.provision "shell", reboot: true

      # ========================================================================
      # PHASE 7: VULNERABLE CONFIGURATION (CRED-2 ATTACK PATH)
      # ========================================================================      
      # - Deploys task sequence to All Systems collection
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/services/SCCM/Vuln-TS-Variables.ps1"
      config.vm.provision "shell", reboot: true

      # ========================================================================
      # PHASE 7: VULNERABLE CLIENT PUSH Installation
      # ========================================================================

      # Configure VULNERABLE SCCM client push for CRED-1 attack simulation:
      # - Enables client push installation
      # - Configures client push for all systems
      # - Adds SILENT\sccm_cpia to client push account
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/services/SCCM/Vuln-ClientPush.ps1"
      config.vm.provision "shell", reboot: true

      # ========================================================================
      # PHASE 8: VULNERABLE DISTRIBUTION POINT (Anon DP LOOTING)
      # ========================================================================
      # - Deploys a vulnerable package to All Systems collection
      # - Adds SILENT\sccm_cpia to client push account
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/services/SCCM/Vuln-App-Package.ps1"
      # config.vm.provision "shell", reboot: true

      # configure network 
      config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/networking/network-setup.ps1"
      config.vm.provision "shell", reboot: true
 

    end




  #   # This is a child domain controller with standard configuration. 
  #   # It creates another  child domain and populates the domain with AD objects like users and groups. 
  #   # It can also create specific GPOs and serve as DNS server.
  #   cfg.vm.define "ChildDC" do |config|
  #     config.vm.box = "StefanScherer/windows_2019"
  #     config.vm.box_version = "2018.10.03"
  #     config.vm.hostname = dc_name 

  #     # Use the plaintext WinRM transport and force it to use basic authentication.
  #     # NB this is needed because the default negotiate transport stops working
  #     #    after the domain controller is installed.
  #     #    see https://groups.google.com/forum/#!topic/vagrant-up/sZantuCM0q4
  #     config.winrm.transport = :plaintext 
  #     config.winrm.basic_auth_only = true
  #     config.winrm.retry_limit = 30
  #     config.winrm.retry_delay = 10

  #     config.vm.provider :virtualbox do |v, override|
  #         v.name = dc_name
  #         v.linked_clone = true  # <--- THIS SAVES 30GB+ across the lab
  #         v.gui = false
  #         v.cpus = 4
  #         v.memory = 4096
  #         v.customize ["modifyvm", :id, "--vram", 64]
  #     end

  #     config.vm.network :private_network,
  #         :ip => dc_ip
      
  #     # #https://github.com/rgl/vagrant-windows-sysprep  ## Without it ALL MACHINES gonna have same SID -__-
  #     config.vm.provision "windows-sysprep"
  #     config.vm.provision "shell", reboot: true
          
  #     # Configure keyboard/language/timezone/Firewall etc.
  #     config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/windows/provision-base.ps1"

  #     # Disable License service to prevent machines from automatic shutdown.
  #     config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/windows/disable-license-service.ps1"
  #     config.vm.provision "shell", reboot: true
      

  #     # Create child domain
  #     # begin
  #       config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/ad/install-domain.ps1 domain-variables.json forest-variables.json"
  #     # rescue
  #     #   # Exit if user chooses not to continue
  #     #   exit 1 unless prompt_on_error(e.message)
  #     # end
  #     config.vm.provision "shell", reboot: true

  #     # Configure DNS
  #     config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/networking/network-setup.ps1 network-setup-dc.ps1 dns_entries.csv"
  #     config.vm.provision "shell", reboot: true
      


  #     # Add OUs, users, groups, etc. See the script to generate new users
  #     # begin
  #     config.vm.provision "shell", path: "sharedscripts/vulns/vuln-ad.ps1", args: [ad_fqdn, 100] #, run: "always"

  #     # rescue => e
  #     #   # Exit if user chooses not to continue
  #     #   exit 1 unless prompt_on_error(e.message)
  #     # end
  #     config.vm.provision "shell", reboot: true
  #     # config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/networking/network-setup.ps1 network-setup-dc.ps1 dns_entries.csv"
  #     # config.vm.provision "shell", reboot: true      
  # end  


  
    #This is a domain controller with standard configuration. It creates a single forest and populates the domain with AD objects like users and groups. It can also create specific GPOs and serve as DNS server.
    # cfg.vm.define "server1" do |config|
    #   config.vm.box = "StefanScherer/windows_2019"
    #   config.vm.box_version = "2018.10.03"
    #   config.vm.hostname = server_name
    #
    #   # Use the plaintext WinRM transport and force it to use basic authentication.
    #   # NB this is needed because the default negotiate transport stops working
    #   #    after the domain controller is installed.
    #   #    see https://groups.google.com/forum/#!topic/vagrant-up/sZantuCM0q4
    #   config.winrm.transport = :plaintext 
    #   config.winrm.basic_auth_only = true
    #   config.winrm.retry_limit = 30
    #   config.winrm.retry_delay = 10
    #
    #   config.vm.provider :virtualbox do |v, override|
    #       v.name = server_name
    #       v.gui = false
    #       v.cpus = 2
    #       v.memory = 2048
    #       v.customize ["modifyvm", :id, "--vram", 64]
    #   end
    #
    #   config.vm.network :private_network,
    #       :ip => server_ip
    #   
    #   #https://github.com/rgl/vagrant-windows-sysprep
    #   # config.vm.provision "windows-sysprep"
    #   # config.vm.provision "shell", reboot: true
    #       
    #   # # Configure firewall/keyboard/language/timezone etc.
    #   # config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/windows/provision-base.ps1"
    #   # config.vm.provision "shell", reboot: true
    #
    #   # # Disable License service to prevent machines from automatic shutdown.
    #   # config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/windows/disable-license-service.ps1"
    #   # config.vm.provision "shell", reboot: true
    #   
    #   #Join the domain specified in provided variables file - Only do this after everything else has been installed
    #   # config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/ad/join-domain.ps1 forest-variables.json"
    #   # config.vm.provision "shell", reboot: true
    #
    #   # Configure DNS
    #   # config.vm.provision "shell", path: "sharedscripts/ps.ps1", args: "sharedscripts/networking/network-setup.ps1"
    #   # config.vm.provision "shell", reboot: true      
    #
    #   #Reboot so that scheduled task runs
    #   # config.vm.provision "shell", reboot: true
    #
    # end  
end
