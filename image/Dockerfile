# SavaPage + CUPS in one container. Built by .github/workflows/image.yaml only
# when a new SavaPage release appears (or this directory changes).
FROM debian:bookworm-slim

# Installer file name from https://download.savapage.org/installer/
ARG SAVAPAGE_INSTALLER=savapage-setup-1.7.0-final-linux-x64.bin

# Package list per the SavaPage manual (JDK 11+, CUPS) plus the converters it
# shells out to for PDF/image/HTML rendering.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      binutils ca-certificates cpio cups cups-bsd curl debianutils \
      default-jdk-headless gzip imagemagick libheif-examples librsvg2-bin \
      perl poppler-utils procps qpdf wkhtmltopdf \
 && rm -rf /var/lib/apt/lists/*

# The account name is fixed by SavaPage; lpadmin lets it manage CUPS queues.
RUN useradd -r -m -d /opt/savapage -s /bin/bash -G lpadmin savapage

WORKDIR /opt/savapage
RUN curl -fsSLO "https://download.savapage.org/installer/${SAVAPAGE_INSTALLER}" \
 && curl -fsSL https://download.savapage.org/sha512sums.txt \
      | grep " installer/${SAVAPAGE_INSTALLER}$" \
      | sed 's# installer/# #' | sha512sum -c - \
 && chown savapage:savapage "${SAVAPAGE_INSTALLER}" \
 && su savapage -c "sh ./${SAVAPAGE_INSTALLER} -n" \
 && rm "${SAVAPAGE_INSTALLER}"

# Only the PAM part of the root tasks: the rest installs a systemd unit and
# starts the server, which the entrypoint does instead. The CUPS notifier is
# installed at runtime, once cupsd and the server are up.
RUN /opt/savapage/server/bin/linux-x64/roottasks pam \
 && cp -a /opt/savapage/server/data /opt/savapage/server/data.dist \
 && cp -a /etc/cups /etc/cups.dist

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

EXPOSE 8631 631
VOLUME ["/opt/savapage/server/data", "/etc/cups"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve"]
