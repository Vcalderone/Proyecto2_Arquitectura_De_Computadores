"""Error type used across the assembler."""


class AssemblerError(Exception):
    """Raised for any malformed input, with the source line number attached."""

    def __init__(self, line, message):
        self.line = line
        self.message = message
        if line is None:
            super().__init__(message)
        else:
            super().__init__(f"line {line}: {message}")
