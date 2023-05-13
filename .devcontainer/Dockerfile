FROM mcr.microsoft.com/devcontainers/rust:0-1-bullseye

USER vscode

RUN sudo apt-get update && \
	sudo apt-get install vim -y

RUN curl -L https://foundry.paradigm.xyz | bash

SHELL ["/bin/bash", "--login", "-i", "-c"]
RUN foundryup