FROM perl:5.38-slim

# Install system dependencies required for compiling SSL modules
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Mojolicious and SSL packages for HTTPS UserAgent support
RUN cpanm --notest Mojolicious IO::Socket::SSL Net::SSLeay

# Set the working directory inside the container
WORKDIR /usr/src/app

# Copy the backend script and the static public assets
COPY backend.pl .
COPY public/ ./public/

# Expose port 3001 as configured in backend.pl
EXPOSE 3001

# Run the backend using Hypnotoad in foreground mode so the container stays active
CMD ["hypnotoad", "-f", "backend.pl"]