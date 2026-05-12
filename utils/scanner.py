import os
import re
import json
import logging

# Setup logging
logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')
logger = logging.getLogger(__name__)

def scan_project(root_dir):
    """Scans the project directory and extracts nodes and links for visualization."""
    nodes = []
    links = []
    
    # Directories to ignore
    exclude_dirs = {'.git', '__pycache__', 'node_modules', '.github', 'temp_hls', 'recordings', 'venv', '.vscode', '.idea'}
    exclude_files = {'.DS_Store', 'graph_data.json'}
    
    # Map from relative path to node metadata
    path_to_node = {}
    
    logger.info(f"Scanning directory: {root_dir}")
    
    # 1. First pass: Collect all files and directories to build the hierarchy
    for root, dirs, files in os.walk(root_dir):
        # Filter excluded directories in-place
        dirs[:] = [d for d in dirs if d not in exclude_dirs]
        
        rel_root = os.path.relpath(root, root_dir)
        if rel_root == '.':
            rel_root = ''
            
        # Add directory node
        if rel_root:
            dir_id = rel_root.replace(os.sep, '/')
            if dir_id not in path_to_node:
                node = {
                    "id": dir_id,
                    "name": os.path.basename(root),
                    "type": "directory",
                    "group": 1,
                    "val": 5 # Size for force graph
                }
                path_to_node[dir_id] = node
                nodes.append(node)
                
                # Link to parent directory
                parent_dir = os.path.dirname(dir_id)
                if parent_dir:
                    links.append({"source": parent_dir, "target": dir_id, "type": "hierarchy", "value": 1})
                else:
                    # Top-level directory linked to a virtual root or just left floating
                    pass
        
        for file in files:
            if file in exclude_files or file.startswith('.'):
                continue
            
            rel_path = os.path.join(rel_root, file).replace(os.sep, '/')
            file_id = rel_path
            
            # Determine group based on file extension
            ext = os.path.splitext(file)[1].lower()
            group_map = {
                '.py': 2,
                '.html': 3,
                '.css': 4,
                '.js': 5,
                '.md': 6,
                '.sh': 7,
                '.txt': 8,
                '.json': 9,
                '.yml': 10,
                '.yaml': 10
            }
            group = group_map.get(ext, 11)
            
            file_size = os.path.getsize(os.path.join(root, file))
            node = {
                "id": file_id,
                "name": file,
                "type": "file",
                "group": group,
                "size": file_size,
                "val": min(max(file_size / 1024, 2), 15) # Scaled value for node size
            }
            path_to_node[file_id] = node
            nodes.append(node)
            
            # Link to parent directory
            parent_dir = rel_root.replace(os.sep, '/')
            if parent_dir:
                links.append({"source": parent_dir, "target": file_id, "type": "hierarchy", "value": 1})

    # 2. Second pass: Parse Python files for imports
    import_re = re.compile(r'^(?:from|import)\s+([\w\.]+)', re.MULTILINE)
    
    for node in nodes:
        if node['type'] == 'file' and node['id'].endswith('.py'):
            file_path = os.path.join(root_dir, node['id'].replace('/', os.sep))
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                    # Basic extraction of imports
                    imports = import_re.findall(content)
                    
                    for imp in imports:
                        # Try to resolve internal imports
                        # Example: 'services.hls_proxy' or 'config'
                        parts = imp.split('.')
                        
                        # 1. Try absolute import from root (e.g. services.hls_proxy)
                        pot_paths = [
                            os.path.join(*parts) + '.py',
                            os.path.join(*parts, '__init__.py')
                        ]
                        
                        # 2. Try relative import if we can determine the context
                        # (Simplification: just check if the last part is a file in the same dir)
                        current_dir = os.path.dirname(node['id'])
                        pot_paths.append(os.path.join(current_dir, parts[-1] + '.py'))
                        
                        for pot in pot_paths:
                            pot_rel = pot.replace(os.sep, '/')
                            if pot_rel in path_to_node and pot_rel != node['id']:
                                links.append({
                                    "source": node['id'],
                                    "target": pot_rel,
                                    "type": "import",
                                    "value": 2
                                })
                                break
            except Exception as e:
                logger.error(f"Error parsing {file_path}: {e}")

    return {"nodes": nodes, "links": links}

if __name__ == "__main__":
    # Assuming this script is in project_root/utils/scanner.py
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
    
    try:
        data = scan_project(project_root)
        
        static_dir = os.path.join(project_root, 'static')
        if not os.path.exists(static_dir):
            os.makedirs(static_dir)
            
        output_path = os.path.join(static_dir, 'graph_data.json')
        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2)
            
        logger.info(f"Successfully generated graph data with {len(data['nodes'])} nodes and {len(data['links'])} links.")
        logger.info(f"Output saved to: {output_path}")
    except Exception as e:
        logger.error(f"Failed to scan project: {e}")
