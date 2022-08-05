def bytes_to_size(b):
    # 512 to convert to bytes from du -s output
    # b = b * 512 * 19.376 / 18.1818  # factor to approximate to base 10
    b *= 1000 * 19.976 / 18.1818
    if b < 1024:
        return str(b) + "B"
    elif b < 1024 * 1024:
        return str(round(b / 1024, 2)) + "KB"
    elif b < 1024 * 1024 * 1024:
        return str(round(b / 1024 / 1024, 2)) + "MB"
    else:
        return str(round(b / 1024 / 1024 / 1024, 2)) + "GB"


def main():
    arm64_cleaned = [line.split() for line in open("cleaned_arm64.txt", "r")]
    # x86_64_cleaned = [line.split() for line in open("cleaned_x86_64.txt", "r")]
    original = [line.split() for line in open("original_sizes.txt", "r")]
    original_dict = {" ".join(line[1::]): line[0] for line in original}

    total_original = 0
    total_arm64 = 0
    total_x86_64 = 0
    cleaned = []

    for line in arm64_cleaned:
        clean_size = int(line[0])
        original_size = int(original_dict[" ".join(line[1::])])
        total_arm64 += clean_size
        total_original += original_size
        cleaned.append([clean_size, original_size, " ".join(line[1::])])

    cleaned.sort(key=lambda x: x[1] - x[0], reverse=True)

    for i in range(len(cleaned)):
        print(
            f"{cleaned[i][2]}: ",
            bytes_to_size(cleaned[i][1]),
            bytes_to_size(cleaned[i][0]),
            str(round((1 - (cleaned[i][0] / cleaned[i][1])) * 100, 2)) + "%",
            f"{bytes_to_size(cleaned[i][1]-cleaned[i][0] )}",
        )

    print(
        "\ntotal arm64:",
        bytes_to_size(total_arm64),
        "total original:",
        bytes_to_size(total_original),
        "percentage:",
        round((1 - (total_arm64 / total_original)) * 100, 2),
        "%",
    )
    print("saved:", bytes_to_size(total_original - total_arm64))

    total_original = 0
    # print("\n")

    # for line in x86_64_cleaned:
    #     clean_size = int(line[0])
    #     original_size = int(original_dict[line[1]])
    #     total_x86_64 += clean_size
    #     total_original += original_size
    #     print(
    #         f"{line[1]}: ",
    #         original_size,
    #         "->",
    #         clean_size,
    #         round(clean_size / original_size * 100, 2),
    #         "%",
    #     )

    # print(
    #     "Total x86_64:",
    #     bytes_to_size(total_x86_64),
    #     "Total original:",
    #     bytes_to_size(total_original),
    #     "Percentage:",
    #     round((1 - (clean_size / original_size)) * 100, 2),
    #     "%",
    # )


if __name__ == "__main__":
    main()
