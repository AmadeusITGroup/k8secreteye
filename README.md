# K8SecretEye

K8SecretEye is a powerful Kubernetes secret seeker tool. It searches for sensitive information, such as secrets, in pod logs and YAML definitions. This tool helps you ensure that no sensitive information is mistakenly exposed in your Kubernetes cluster.

## Features

- Searches for secrets in Kubernetes pod logs.
- Scans YAML definitions for sensitive information.
- Customizable with a wordlist for patterns to look for.
- Simple and easy to use.

## Getting Started

These instructions will help you get a copy of the K8SecretEye project up and running on your local machine for development and testing purposes.

### Prerequisites

Ensure you have the following installed before using K8SecretEye:

- Bash
- `kubectl`or `oc` installed and configured
- gzip package matching your distribution

### Installation

1. Clone the repository:
    
    `git clone https://github.com/AmadeusITGroup/K8SecretEye.git cd K8SecretEye`
    
2. Customize the `wordlist.txt` with any additional patterns you wish to search for.

## Usage

Run the main script to print detailed usage. You can chose between 4 positional arguments: yaml, log, gzip and secret.
By default all dumps will be stored in **k8secreteye** folder.

    **Positional arguments:**

    - `log`: Collect logs from pods
    - `yaml`: Collect YAML resources + gzip/base64 detection
    - `secret`: Detect secrets in collected data
    - `gzip`: Detect gzip/base64 patterns in collected data

    **Options:**

    - `-n namespace`: Specify namespace to target
    - `-p pod`: Specify pod to target
    - `-r resource`: Specify resource type to target (e.g. secrets, configmaps). Leave empty for common resource list or provide 'most' for a more extensive list.
    - `-w wordlist`: Specify custom wordlist file for secret detection (default: wordlist.txt)
    - `-d output_dir`: Specify output directory (default: k8secreteye)
    - `-o`: Optimize YAML collection by dumping all resources in a single request and file
    - `-f`: Overwrite already dumped resource files
    - `-v`: Verbose mode for secret output


**Print usage:**

`bash k8secreteye.sh`

**To dump resource yaml in a specific namespace:**

`bash k8secreteye.sh yaml -n NAMESPACE_NAME`

**To dump logs for a specific pod**

`bash k8secreteye.sh log -n NAMESPACE_NAME -p POD_NAME`

**To search for secrets in dumped resources in /path/to/dump:** 

`bash k8secreteye.sh secret -d /path/to/dump`

**To use another wordlist :**

`bash k8secreteye.sh secret -w /path/to/wlist`