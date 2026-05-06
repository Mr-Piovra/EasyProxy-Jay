import logging
import sys

class Colors:
    """ANSI color codes for terminal output."""
    RESET = "\033[0m"
    DEBUG = "\033[36m"      # Cyan
    INFO = "\033[32m"       # Green
    WARNING = "\033[33m"    # Yellow
    ERROR = "\033[31m"      # Red
    CRITICAL = "\033[1;31m" # Bold Red
    TIME = "\033[90m"       # Gray
    NAME = "\033[34m"       # Blue

class ColoredFormatter(logging.Formatter):
    """Custom logging formatter that adds colors based on log level."""
    
    def format(self, record):
        level_color = getattr(Colors, record.levelname, Colors.RESET)
        
        # Colorize components
        time_str = f"{Colors.TIME}%(asctime)s.%(msecs)03d{Colors.RESET}"
        level_str = f"{level_color}%(levelname)-8s{Colors.RESET}"
        name_str = f"{Colors.NAME}%(name)-15s{Colors.RESET}"
        
        # Format the actual message
        format_str = f"{time_str} | {level_str} | {name_str} | %(message)s"
        formatter = logging.Formatter(format_str, datefmt="%Y-%m-%d %H:%M:%S")
        
        return formatter.format(record)

class AsyncioWarningFilter(logging.Filter):
    """Filter out annoying asyncio child process warnings."""
    def filter(self, record):
        return "Unknown child process pid" not in record.getMessage()

def setup_logger(level=logging.INFO):
    """
    Configure the root logger with colors, formatters, and silence noisy third-party loggers.
    """
    root_logger = logging.getLogger()
    root_logger.setLevel(level)
    
    # Clear existing handlers to avoid duplicates
    for handler in root_logger.handlers[:]:
        root_logger.removeHandler(handler)
        
    # Setup console handler with the custom colored formatter
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(ColoredFormatter())
    root_logger.addHandler(console_handler)
    
    # Silence noisy 3rd party loggers unless global level is DEBUG
    noisy_loggers = ["aiohttp.access", "urllib3", "asyncio"]
    target_level = logging.WARNING if level > logging.DEBUG else logging.DEBUG
    
    for logger_name in noisy_loggers:
        logging.getLogger(logger_name).setLevel(target_level)
        
    # Apply specific asyncio filter
    logging.getLogger("asyncio").addFilter(AsyncioWarningFilter())
