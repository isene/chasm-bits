PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin

PROGRAMS = date clock uptime brightness sep mailbox cpu mem disk battery ip moonphase ping pingok mailfetch

all: $(PROGRAMS)

%: %.asm
	nasm -f elf64 $< -o $*.o
	ld $*.o -o $@
	rm -f $*.o

install: $(PROGRAMS)
	@for p in $(PROGRAMS); do \
	  install -Dm755 $$p $(DESTDIR)$(BINDIR)/bits-$$p; \
	  echo "Installed $$p as $(BINDIR)/bits-$$p"; \
	done

uninstall:
	@for p in $(PROGRAMS); do \
	  rm -f $(DESTDIR)$(BINDIR)/bits-$$p; \
	done

clean:
	rm -f $(PROGRAMS) *.o

.PHONY: all install uninstall clean
