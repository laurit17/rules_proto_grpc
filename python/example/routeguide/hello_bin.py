from python.example.routeguide.hello import hello


if __name__ == '__main__':

    import sys
    print(sys.path)
    from example.proto import person_pb2, place_pb2, foo_pb2
    person = person_pb2.Person()
    place = place_pb2.Place()
    hello()