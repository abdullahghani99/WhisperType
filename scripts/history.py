"""Fetch and format history, including configured authentication."""
import argparse
import io
import json
import os
from pathlib import Path
import runpy
import sys
import urllib.error
import urllib.request

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('limit',type=int,nargs='?',default=15)
    args=parser.parse_args()
    if not 1 <= args.limit <= 1000: parser.error('limit must be between 1 and 1000')
    url=os.environ.get('VF_SERVER_URL','http://127.0.0.1:8790').rstrip('/')
    key=os.environ.get('VF_API_KEY','')
    request=urllib.request.Request(f'{url}/history?limit={args.limit}',headers={'Authorization':'Bearer '+key} if key else {})
    try:
        with urllib.request.urlopen(request,timeout=8) as response: data=json.load(response)
        if not isinstance(data,dict) or not isinstance(data.get('items'),list) or 'total' not in data:
            raise ValueError('Server returned an invalid history response')
    except (OSError,ValueError) as error:
        parser.exit(1,f'History unavailable: {error}\n')
    sys.stdin=io.StringIO(json.dumps(data))
    runpy.run_path(str(Path(__file__).with_name('_history_print.py')),run_name='__main__')

if __name__=='__main__': main()
