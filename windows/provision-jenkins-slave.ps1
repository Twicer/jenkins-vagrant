param(
    [Parameter(Mandatory=$true)]
    [string]$config_jenkins_master_fqdn = 'jenkins.example.com',

    [Parameter(Mandatory=$true)]
    [string]$config_fqdn = 'windows.jenkins.example.com'
)

# install git and related applications.
choco install -y git --params '/GitOnlyOnPath /NoAutoCrlf /SChannel'
choco install -y gitextensions
choco install -y meld

# update $env:PATH with the recently installed Chocolatey packages.
Import-Module "$env:ChocolateyInstall\helpers\chocolateyInstaller.psm1"
Update-SessionEnvironment

# configure git.
# see http://stackoverflow.com/a/12492094/477532
git config --global user.name 'Rui Lopes'
git config --global user.email 'rgl@ruilopes.com'
git config --global http.sslbackend schannel
git config --global push.default simple
git config --global core.autocrlf false
git config --global diff.guitool meld
git config --global difftool.meld.path 'C:/Program Files (x86)/Meld/Meld.exe'
git config --global difftool.meld.cmd '\"C:/Program Files (x86)/Meld/Meld.exe\" \"$LOCAL\" \"$REMOTE\"'
git config --global merge.tool meld
git config --global mergetool.meld.path 'C:/Program Files (x86)/Meld/Meld.exe'
git config --global mergetool.meld.cmd '\"C:/Program Files (x86)/Meld/Meld.exe\" \"$LOCAL\" \"$BASE\" \"$REMOTE\" --auto-merge --output \"$MERGED\"'
#git config --list --show-origin

# install testing tools.
choco install -y xunit
choco install -y reportgenerator.portable
# NB we need to install a recent (non-released) version due
#    to https://github.com/OpenCover/opencover/issues/736
Push-Location opencover-rgl.portable
choco pack
choco install -y opencover-rgl.portable -Source $PWD
Pop-Location

# install troubeshooting tools.
choco install -y procexp
choco install -y procmon

# add start menu entries.
Install-ChocolateyShortcut `
    -ShortcutFilePath 'C:\Users\All Users\Microsoft\Windows\Start Menu\Programs\Process Explorer.lnk' `
    -TargetPath 'C:\ProgramData\chocolatey\lib\procexp\tools\procexp64.exe'
Install-ChocolateyShortcut `
    -ShortcutFilePath 'C:\Users\All Users\Microsoft\Windows\Start Menu\Programs\Process Monitor.lnk' `
    -TargetPath 'C:\ProgramData\chocolatey\lib\procmon\tools\procmon.exe'

# import the Jenkins master site https certificate into the local machine trust store.
Import-Certificate `
    -FilePath C:/vagrant/tmp/$config_jenkins_master_fqdn-crt.der `
    -CertStoreLocation Cert:/LocalMachine/Root

# import the gitlab-vagrant environment site https certificate into the local machine trust store.
if (Test-Path C:/vagrant/tmp/gitlab.example.com-crt.der) {
    Import-Certificate `
        -FilePath C:/vagrant/tmp/gitlab.example.com-crt.der `
        -CertStoreLocation Cert:/LocalMachine/Root
}

# install the JRE.
choco install -y adoptopenjdk8jre
Update-SessionEnvironment

# add our jenkins master self-signed certificate to the default java trust store.
@(
    'C:\Program Files\Java\jre*\lib\security\cacerts'
    'C:\Program Files\Java\jdk*\jre\lib\security\cacerts'
    'C:\Program Files\AdoptOpenJDK\*jre\lib\security\cacerts'
    'C:\Program Files\AdoptOpenJDK\*jdk\jre\lib\security\cacerts'
) | ForEach-Object {Get-ChildItem $_ -ErrorAction SilentlyContinue} | ForEach-Object {
    $keyStore = $_
    $alias = $config_jenkins_master_fqdn
    $keytool = Resolve-Path "$keyStore\..\..\..\bin\keytool.exe"
    $keytoolOutput = &$keytool `
        -noprompt `
        -list `
        -storepass changeit `
        -keystore "$keyStore" `
        -alias "$alias"
    if ($keytoolOutput -match 'keytool error: java.lang.Exception: Alias .+ does not exist') {
        Write-Host "Adding $alias to the java $keyStore keystore..."
        # NB we use Start-Process because keytool writes to stderr... and that
        #    triggers PowerShell to fail, so we work around this by redirecting
        #    stdout and stderr to a temporary file.
        # NB keytool exit code is always 1, so we cannot rely on that.
        Start-Process `
            -FilePath $keytool `
            -ArgumentList `
                '-noprompt',
                '-import',
                '-trustcacerts',
                '-storepass changeit',
                "-keystore `"$keyStore`"",
                "-alias `"$alias`"",
                "-file c:\vagrant\tmp\$config_jenkins_master_fqdn-crt.der" `
            -RedirectStandardOutput "$env:TEMP\keytool-stdout.txt" `
            -RedirectStandardError "$env:TEMP\keytool-stderr.txt" `
            -NoNewWindow `
            -Wait
        $keytoolOutput = Get-Content -Raw "$env:TEMP\keytool-stdout.txt","$env:TEMP\keytool-stderr.txt"
        if ($keytoolOutput -notmatch 'Certificate was added to keystore') {
            Write-Host $keytoolOutput
            throw "failed to import $alias to keystore"
        }
    } elseif ($LASTEXITCODE) {
        Write-Host $keytoolOutput
        throw "failed to list keystore with exit code $LASTEXITCODE"
    }
}

# create the jenkins user account and home directory.
[Reflection.Assembly]::LoadWithPartialName('System.Web') | Out-Null
$jenkinsAccountName = 'jenkins'
$jenkinsAccountPassword = [Web.Security.Membership]::GeneratePassword(32, 8)
$jenkinsAccountPasswordSecureString = ConvertTo-SecureString $jenkinsAccountPassword -AsPlainText -Force
$jenkinsAccountCredential = New-Object `
    Management.Automation.PSCredential `
    -ArgumentList `
        $jenkinsAccountName,
        $jenkinsAccountPasswordSecureString
New-LocalUser `
    -Name $jenkinsAccountName `
    -FullName 'Jenkins Slave' `
    -Password $jenkinsAccountPasswordSecureString `
    -PasswordNeverExpires
# login to force the system to create the home directory.
# NB the home directory will have the correct permissions, only the
#    SYSTEM, Administrators and the jenkins account are granted full
#    permissions to it.
Start-Process -WindowStyle Hidden -Credential $jenkinsAccountCredential -WorkingDirectory 'C:\' -FilePath cmd -ArgumentList '/c'

# configure the jenkins home.
choco install -y pstools
Copy-Item C:\vagrant\windows\configure-jenkins-home.ps1 C:\tmp
psexec `
    -accepteula `
    -nobanner `
    -u $jenkinsAccountName `
    -p $jenkinsAccountPassword `
    -h `
    PowerShell -File C:\tmp\configure-jenkins-home.ps1
Remove-Item C:\tmp\configure-jenkins-home.ps1

# create the storage directory hierarchy.
# grant the SYSTEM, Administrators and $jenkinsAccountName accounts
# Full Permissions to the c:\j directory and children.
$jenkinsDirectory = mkdir c:\j
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
@(
    'SYSTEM'
    'Administrators'
    $jenkinsAccountName
) | ForEach-Object {
    $acl.AddAccessRule((
        New-Object `
            Security.AccessControl.FileSystemAccessRule(
                $_,
                'FullControl',
                'ContainerInherit,ObjectInherit',
                'None',
                'Allow')))
}
$jenkinsDirectory.SetAccessControl($acl)

# download the jnlp jar and install it.
mkdir $jenkinsDirectory\lib | Out-Null
Invoke-WebRequest "https://$config_jenkins_master_fqdn/jnlpJars/agent.jar" -OutFile $jenkinsDirectory\lib\agent.jar

# install jenkins as a service.
# NB jenkins cannot run from a OpenSSH session because it will end up without required groups and rights.
# NB this is needed to run integration tests that use WCF named pipes (WCF creates a Memory Section in the Global namespace with CreateFileMapping).
#    see https://support.microsoft.com/en-us/help/821546/overview-of-the-impersonate-a-client-after-authentication-and-the-crea
# NB this is needed to build unity projects (it needs WMI permissions to get the machine manifest for its activation mechanism).
choco install -y nssm
$serviceUsername = $jenkinsAccountName
$servicePassword = $jenkinsAccountPassword
$serviceName = $jenkinsAccountName
$serviceHome = $jenkinsDirectory.FullName
Write-Host "Creating the $serviceName service..."
mkdir -Force "$serviceHome\logs" | Out-Null
nssm install $serviceName (Get-Command java.exe).Path
nssm set $serviceName AppParameters `
    -jar lib/agent.jar `
    -jnlpUrl "https://$config_jenkins_master_fqdn/computer/windows/slave-agent.jnlp" `
    -secret (Get-Content -Raw c:\vagrant\tmp\slave-jnlp-secret-windows.txt) `
    -workDir $serviceHome
nssm set $serviceName AppDirectory $serviceHome
nssm set $serviceName Start SERVICE_AUTO_START
nssm set $serviceName AppRotateFiles 1
nssm set $serviceName AppRotateOnline 1
nssm set $serviceName AppRotateSeconds 86400
nssm set $serviceName AppRotateBytes 1048576
nssm set $serviceName AppStdout $serviceHome\logs\$serviceName-stdout.log
nssm set $serviceName AppStderr $serviceHome\logs\$serviceName-stderr.log
nssm set $serviceName ObjectName ".\$serviceUsername" $servicePassword
[string[]]$result = sc.exe failure $serviceName reset= 0 actions= restart/60000
if ($result -ne '[SC] ChangeServiceConfig2 SUCCESS') {
    throw "sc.exe failure failed with $result"
}
Start-Service $serviceName

# add default desktop shortcuts (called from a provision-base.ps1 generated script).
[IO.File]::WriteAllText(
    "$env:USERPROFILE\ConfigureDesktop-Jenkins.ps1",
@'
[IO.File]::WriteAllText(
    "$env:USERPROFILE\Desktop\Jenkins Master.url",
    @"
[InternetShortcut]
URL=https://{0}
"@)
'@ -f $config_jenkins_master_fqdn)

# show installation summary.
function Write-Title($title) {
    Write-Host "`n#`n# $title`n"
}
Write-Title 'Installed DotNet version'
Write-Host (Get-DotNetVersion)
Write-Title 'Installed MSBuild version'
MSBuild -version
Write-Title 'Installed chocolatey packages'
choco list -l
