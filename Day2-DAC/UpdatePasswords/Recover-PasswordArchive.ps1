﻿####################################################################################
#.Synopsis 
#    Recover the plaintext password from an encrypted file originally
#    created with the companion script named Update-PasswordArchive.ps1. 
#
#.Description 
#    Recover the plaintext password from an encrypted file originally
#    created with the companion script named Update-PasswordArchive.ps1. The
#    file is encrypted with a public key chosen by the administrator. The
#    password generated by Update-PasswordArchive.ps1 is random.  Recovery
#    of the encrypted password from the file requires possession of the
#    private key corresponding to the chosen public key certificate. 
#
#.Parameter PasswordArchivePath 
#    The local or UNC path to where the encrypted password files are kept. 
#
#.Parameter ComputerName
#    Name of the computer with the local account whose password was reset
#    and whose password was encrypted and saved to a file.  The computer
#    name will match the names of files in the PasswordArchivePath.  This
#    parameter can accept a computer name with a wildcard in it.
#
#.Parameter UserName
#    Name of the local user account whose password was reset and whose password
#    was encrypted and saved to a file.  The username will match the names of
#    files in the PasswordArchivePath.  Default is "Administrator".  If you
#    are not certain, just enter "*" and the last reset will be used, whatever
#    username that may be, or you might use the -ShowAll switch instead.
#
#.Parameter ShowAll
#    Without this switch, only the most recent plaintext password is shown.
#    With this switch, all archived passwords for the computer are shown.
#    This might be necessary when the passwords of multiple local user 
#    accounts are being managed with these scripts.
#
#
#.Example 
#    .\Recover-PasswordArchive.ps1 -ComputerName LAPTOP47 -UserName Administrator
#
#    Displays in plaintext the last recorded password updated on LAPTOP47.
#    The user running this script must have loaded into their local cache
#    the certificate AND private key corresponding to the certificate used
#    to originally encrypt the password archive files in the present
#    working directory.  A smart card may be used instead.  The default 
#    username is "Administrator", so this argument was not actually required.
#
#.Example 
#    .\Recover-PasswordArchive.ps1 -PasswordArchivePath \\server\share -ComputerName WKS*
#
#    Instead of the present working directory of the script, search the
#    password archive files located in \\server\share.  Another local
#    folder can be specified instead of a UNC network path.  The wildcard
#    in the computer name will show the most recent password updates for
#    all matching computer names in \\server\share for the Administrator.
# 
#.Example 
#    .\Recover-PasswordArchive.ps1 -PasswordArchivePath \\server\share -ComputerName LAPTOP47 -ShowAll
#
#    Instead of showing only the last password update for the Administrator account, 
#    show all archived passwords in the \\server\share folder for LAPTOP47.
#
# 
#Requires -Version 2.0 
#
#.Notes 
#  Author: Jason Fossen, Enclave Consulting (http://www.sans.org/windows-security/)  
# Version: 1.1
# Updated: 5.Jun.2013
#   LEGAL: PUBLIC DOMAIN.  SCRIPT PROVIDED "AS IS" WITH NO WARRANTIES OR GUARANTEES OF 
#          ANY KIND, INCLUDING BUT NOT LIMITED TO MERCHANTABILITY AND/OR FITNESS FOR
#          A PARTICULAR PURPOSE.  ALL RISKS OF DAMAGE REMAINS WITH THE USER, EVEN IF
#          THE AUTHOR, SUPPLIER OR DISTRIBUTOR HAS BEEN ADVISED OF THE POSSIBILITY OF
#          ANY SUCH DAMAGE.  IF YOUR STATE DOES NOT PERMIT THE COMPLETE LIMITATION OF
#          LIABILITY, THEN DELETE THIS FILE SINCE YOU ARE NOW PROHIBITED TO HAVE IT.
####################################################################################


Param ($PasswordArchivePath = ".\", $ComputerName = "$env:computername", $UserName = "Administrator", [Switch] $ShowAll) 

# Construct and test path to encrypted password files.
$PasswordArchivePath = $(resolve-path -path $PasswordArchivePath).path
if ($PasswordArchivePath -notlike "*\") { $PasswordArchivePath = $PasswordArchivePath + "\" } 
if (-not $(test-path -path $PasswordArchivePath)) { "`nERROR: Cannot find path: " + $PasswordArchivePath + "`n" ; exit } 


# Get encrypted password files and sort by name, which sorts by tick number, i.e., by creation timestamp.
$files = @(dir ($PasswordArchivePath + "$ComputerName+*+*+*") | sort Name) 
if ($files.count -eq 0) { "`nERROR: No password archives for " + $ComputerName + "`n" ; exit } 


# Filter by UserName and get the latest archive file only, unless -ShowAll is used.
if (-not $ShowAll)
{ 
    $files = $files | where { $_.name -like "*+$($UserName.Trim())+*+*" } 
    if ($files.count -eq 0) { "`nERROR: No password archives for " + $ComputerName + "\" + $UserName + "`n" ; exit }  
    $files = @($files[-1]) 
} 


# Load the current user's certificates and private keys.
$flags = new-object System.Security.Cryptography.X509Certificates.OpenFlags #ReadOnly
$store = new-object System.Security.Cryptography.X509Certificates.X509Store #CurrentUser
if (-not $? -or ($store.GetType().fullname -notlike "*X509Stor*")) { "`nERROR: Could not load your certificates and private keys.`n" ; exit } 
$store.open($flags)
$certstore = $store.Certificates 
$store.close()
if ($certstore.count -eq 0) { "`nERROR: You have no certificates or private keys.`n" ; exit }


# Process encrypted password archive files and $output objects.
foreach ($lastfile in $files) `
{
    $output = ($output = " " | select-object ComputerName,FilePath,UserName,TimeStamp,Thumbprint,Valid,Password)

    $output.ComputerName = $($lastfile.Name -split '\+')[0]
    $output.FilePath = $lastfile.fullname
    $output.UserName = $($lastfile.Name -split '\+')[1]
    $output.TimeStamp = [DateTime][Int64]$($lastfile.Name -split '\+')[2]
    $output.Valid = $false  #Assume password recovery will fail.
    $output.Thumbprint = $($lastfile.Name -split '\+')[3]


    # Check for password reset failure files.
    if ($output.Thumbprint -eq "PASSWORD-RESET-FAILURE") 
    { 
        $output.Password = "ERROR: Try to use prior password(s) for this computer."
        $output
        continue 
    } 


    # Read in password archive binary file.
    [byte[]] $ciphertext = get-content -encoding byte -path $lastfile.fullname 
    if (-not $?) 
    { 
        $output.Password = "ERROR: Failed to read " + $lastfile.fullname
        $output
        continue 
    }  


    # Load the correct certificate and test for possession of private key.
    $certpriv = $certstore | where { $_.thumbprint -eq $output.thumbprint } 
    if (-not $certpriv.hasprivatekey) 
    { 
        $output.Password = "ERROR: You do not have the private key for this certificate."
        $output
        continue
    } 

    
    # Attempt decryption with private key. 
    $plaintextout = $certpriv.privatekey.decrypt($ciphertext,$false)  #Must be $false for smart card to work.
    if (-not $?) { $output.Password = "ERROR: Decryption failed." }
    else { $output.Password = ([char[]]$plaintextout -join "") } 


    # Confirm that archive file name matches the nonce string encrypted into the file.
    # Nonce might help to thwart spoofers and can be used for troubleshooting.
    if ($lastfile.name -like $output.Password.substring(0,60) + "*") 
    { 
        $output.Password = $output.Password.substring(60) #Strip out the 60-char nonce.
        $output.Valid = $true 
    }
    else
    { 
        $output.Password = $output.Password.substring(60) #Strip out the 60-char nonce.
        $output.Password = "ERROR: Integrity check failure: " + $output.Password.substring(60) + "  (" + $output.Password + ")" 
    } 


    $output
}



