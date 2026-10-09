"""Watch state['player']['score'] while its containing dictionary changes."""


def main():
    state = {'player': {'score': 7}}
    for score in range(7, 17):
        state['player'] = {'score': score}
        print(state['player']['score'], flush=True)


main()
